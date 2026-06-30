import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// 顔（`DetectedFace`）・クラスタ（`PersonCluster`）・スキャン済みマーカー（`ScannedPhoto`）を司る ModelActor。
/// CLIP の `AutoAlbumStore` とは**別コンテナ**（"FacesV1"）なので、顔機能の追加で既存データを壊さない。
/// `@Model` は actor 外へ出さず、Sendable 値（`PersonInfo` 等）に変換して返す。
@ModelActor
actor FaceStore {
    private static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Faces")

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        let schema = Schema([DetectedFace.self, PersonCluster.self, ScannedPhoto.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return AutoAlbumStore.makeResilientContainer(name: "FacesV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    /// 同一クラスタとみなすコサイン下限（facenet 正規化埋め込みの目安）。
    private static let clusterThreshold: Float = 0.45

    // MARK: - スキャン進捗

    /// スキャン済みの refKey 集合（tagger が候補からメモリ差分を取るため一度だけ取得する）。
    func scannedRefKeys() -> Set<String> {
        let markers = (try? modelContext.fetch(FetchDescriptor<ScannedPhoto>())) ?? []
        return Set(markers.map(\.refKey))
    }

    func scannedCount() -> Int { (try? modelContext.fetchCount(FetchDescriptor<ScannedPhoto>())) ?? 0 }
    func faceCount() -> Int { (try? modelContext.fetchCount(FetchDescriptor<DetectedFace>())) ?? 0 }

    // MARK: - 記録＋逐次クラスタリング

    /// 1 写真分の検出結果を記録する（顔行＋マーカー）。各顔を既存クラスタへ逐次割り当てる。
    func recordScan(refKey: String, faces: [DetectedFaceSignal]) {
        // すでに記録済みなら二重記録しない。
        let key = refKey
        var marker = FetchDescriptor<ScannedPhoto>(predicate: #Predicate { $0.refKey == key })
        marker.fetchLimit = 1
        if (try? modelContext.fetch(marker).first) != nil { return }

        modelContext.insert(ScannedPhoto(refKey: refKey, faceCount: faces.count))

        if !faces.isEmpty {
            var clustering = loadClustering()
            for (i, face) in faces.enumerated() {
                guard let vec = ClipMath.decodeHalf(face.embedding) else { continue }
                let faceID = "\(refKey)#\(i)"
                let cid = clustering.assign(faceID: faceID, embedding: vec)
                modelContext.insert(DetectedFace(
                    faceID: faceID, refKey: refKey,
                    bx: face.boundingBox.origin.x, by: face.boundingBox.origin.y,
                    bw: face.boundingBox.size.width, bh: face.boundingBox.size.height,
                    embedding: face.embedding, quality: Double(face.quality), clusterID: cid))
            }
            persist(clustering)
        }
        try? modelContext.save()
    }

    /// 永続化済みクラスタを `FaceClustering` に復元する（重心・件数・代表顔まで）。
    private func loadClustering() -> FaceClustering {
        let records = (try? modelContext.fetch(FetchDescriptor<PersonCluster>())) ?? []
        var seed: [FaceClustering.Cluster] = []
        for r in records {
            guard let sum = ClipMath.decodeHalf(r.sum) else { continue }
            seed.append(FaceClustering.Cluster(
                id: r.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: r.count, faceIDs: r.coverFaceID.map { [$0] } ?? []))
        }
        return FaceClustering(threshold: Self.clusterThreshold, seedClusters: seed)
    }

    /// クラスタリング結果を `PersonCluster` テーブルへ書き戻す（sum/count・新規は代表顔を設定）。
    private func persist(_ clustering: FaceClustering) {
        for c in clustering.clusters {
            let cid = c.id
            var d = FetchDescriptor<PersonCluster>(predicate: #Predicate { $0.clusterID == cid })
            d.fetchLimit = 1
            if let existing = try? modelContext.fetch(d).first {
                existing.sum = ClipMath.encodeHalf(c.sum)
                existing.count = c.count
                if existing.coverFaceID == nil { existing.coverFaceID = c.faceIDs.first }
            } else {
                modelContext.insert(PersonCluster(
                    clusterID: c.id, sum: ClipMath.encodeHalf(c.sum), count: c.count,
                    name: nil, coverFaceID: c.faceIDs.first))
            }
        }
    }

    // MARK: - 取り出し（表示用）

    /// 「人物」とみなすクラスタ（メンバー数 `minFaces` 以上）を多い順に返す。
    func peopleClusters(minFaces: Int = 3) -> [PersonInfo] {
        let clusters = (try? modelContext.fetch(FetchDescriptor<PersonCluster>())) ?? []
        var result: [PersonInfo] = []
        for c in clusters where c.count >= minFaces {
            let cid = c.clusterID
            let faces = (try? modelContext.fetch(
                FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid }))) ?? []
            // 写真キーは重複排除（同一写真に同一人物が複数顔ある場合）。
            var seen = Set<String>()
            var members: [String] = []
            for f in faces where seen.insert(f.refKey).inserted { members.append(f.refKey) }

            let cover = c.coverFaceID.flatMap { fid in faces.first { $0.faceID == fid } } ?? faces.first
            let box = cover.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
            result.append(PersonInfo(
                clusterID: c.clusterID, name: c.name, count: members.count,
                coverRefKey: cover?.refKey, coverBoundingBox: box, memberRefKeys: members))
        }
        return result.sorted { $0.count > $1.count }
    }

    func rename(clusterID: Int, name: String?) {
        let cid = clusterID
        var d = FetchDescriptor<PersonCluster>(predicate: #Predicate { $0.clusterID == cid })
        d.fetchLimit = 1
        if let c = try? modelContext.fetch(d).first {
            c.name = (name?.isEmpty == true) ? nil : name
            try? modelContext.save()
        }
    }

    /// 全消去（再スキャン用）。
    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        try? modelContext.save()
    }
}
