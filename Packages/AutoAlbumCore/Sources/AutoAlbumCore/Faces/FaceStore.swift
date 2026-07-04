import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// 顔（`DetectedFace`）・クラスタ（`PersonCluster`）・スキャン済みマーカー（`ScannedPhoto`）を司る ModelActor。
/// CLIP の `AutoAlbumStore` とは**別コンテナ**（"FacesV1"）なので、顔機能の追加で既存データを壊さない。
/// `@Model` は actor 外へ出さず、Sendable 値（`PersonInfo` 等）に変換して返す。
/// 重心（sum/count）の演算は `FaceClustering` の純関数に寄せ、ここは fetch/persist に徹する。
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

    // MARK: - Fetch helpers（FetchDescriptor の反復をここに集約）

    private func cluster(_ clusterID: Int) -> PersonCluster? {
        let cid = clusterID
        var d = FetchDescriptor<PersonCluster>(predicate: #Predicate { $0.clusterID == cid })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func allClusters() -> [PersonCluster] {
        (try? modelContext.fetch(FetchDescriptor<PersonCluster>())) ?? []
    }

    private func face(byID faceID: String) -> DetectedFace? {
        let fid = faceID
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.faceID == fid })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    private func faces(inCluster clusterID: Int) -> [DetectedFace] {
        let cid = clusterID
        return (try? modelContext.fetch(
            FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid }))) ?? []
    }

    private func faces(inPhoto refKey: String) -> [DetectedFace] {
        let key = refKey
        return (try? modelContext.fetch(
            FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.refKey == key }))) ?? []
    }

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
        var seed: [FaceClustering.Cluster] = []
        for r in allClusters() {
            guard let sum = ClipMath.decodeHalf(r.sum) else { continue }
            seed.append(FaceClustering.Cluster(
                id: r.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: r.count, faceIDs: r.coverFaceID.map { [$0] } ?? []))
        }
        return FaceClustering(threshold: Self.clusterThreshold, seedClusters: seed)
    }

    /// クラスタリング結果を `PersonCluster` テーブルへ書き戻す（sum/count のみ）。
    /// `coverFaceID` は**ユーザーが代表写真を選んだときだけ** `setCover` が書く。未設定（nil）の
    /// 代表は読み出し時（`peopleClusters`）に「お気に入り優先→先頭」で自動選択する。
    private func persist(_ clustering: FaceClustering) {
        for c in clustering.clusters {
            if let existing = cluster(c.id) {
                existing.sum = ClipMath.encodeHalf(c.sum)
                existing.count = c.count
            } else {
                modelContext.insert(PersonCluster(
                    clusterID: c.id, sum: ClipMath.encodeHalf(c.sum), count: c.count,
                    name: nil, coverFaceID: nil))
            }
        }
    }

    // MARK: - 取り出し（表示用）

    /// 「人物」とみなすクラスタ（メンバー数 `minFaces` 以上）を多い順に返す。
    /// 代表写真（cover）の優先順位: ユーザーが選んだ顔（`coverFaceID`・現存するもの）
    /// → **お気に入りマークの写真**の顔（`favoriteRefKeys`）→ 認識した写真の先頭。
    func peopleClusters(minFaces: Int = 3, favoriteRefKeys: Set<String> = []) -> [PersonInfo] {
        var result: [PersonInfo] = []
        for c in allClusters() where c.count >= minFaces {
            let faces = faces(inCluster: c.clusterID)
            // 写真キーは重複排除（同一写真に同一人物が複数顔ある場合）。
            var seen = Set<String>()
            var members: [String] = []
            for f in faces where seen.insert(f.refKey).inserted { members.append(f.refKey) }

            let cover = c.coverFaceID.flatMap { fid in faces.first { $0.faceID == fid } }
                ?? faces.first { favoriteRefKeys.contains($0.refKey) }
                ?? faces.first
            let box = cover.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
            result.append(PersonInfo(
                clusterID: c.clusterID, name: c.name, count: members.count,
                coverRefKey: cover?.refKey, coverBoundingBox: box, memberRefKeys: members))
        }
        return result.sorted { $0.count > $1.count }
    }

    /// クラスタの顔候補（写真ごとに 1 つ・代表写真ピッカー用）。
    func facesForCluster(clusterID: Int) -> [PersonInfo.Face] {
        var seen = Set<String>()
        var out: [PersonInfo.Face] = []
        for f in faces(inCluster: clusterID) where seen.insert(f.refKey).inserted {
            out.append(PersonInfo.Face(
                faceID: f.faceID, refKey: f.refKey,
                boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh)))
        }
        return out
    }

    /// この写真に写っている「人物」の表示名（フル画像ビューの People 表示用）。
    /// 顔が属するクラスタのうち、人物とみなせる（`minFaces` 以上）ものの名前を返す。複数可。
    func peopleNames(refKey: String, minFaces: Int) -> [String] {
        var out: [String] = []
        var seen = Set<Int>()
        for f in faces(inPhoto: refKey) where seen.insert(f.clusterID).inserted {
            guard let c = cluster(f.clusterID), c.count >= minFaces else { continue }
            out.append(c.name ?? "Person \(f.clusterID + 1)")
        }
        return out
    }

    /// 代表写真（cover）を指定した顔に設定する。
    func setCover(clusterID: Int, faceID: String) {
        guard let c = cluster(clusterID) else { return }
        c.coverFaceID = faceID
        try? modelContext.save()
    }

    // MARK: - 付け替え（「この人は別の人」）

    /// 顔を別の人物へ付け替える。`toClusterID` が nil なら新規人物を作る。
    /// 重心演算は `FaceClustering.adding/removing`（`assign` と同じ正規化規則）に委譲する。
    func reassignFace(faceID: String, toClusterID: Int?) {
        guard let face = face(byID: faceID),
              let vec = ClipMath.decodeHalf(face.embedding) else { return }
        let oldCID = face.clusterID
        guard oldCID != toClusterID else { return }

        removeFromCluster(clusterID: oldCID, vec: vec, faceID: faceID)
        let targetCID = toClusterID ?? nextClusterID()
        addToCluster(clusterID: targetCID, vec: vec, faceID: faceID)
        face.clusterID = targetCID
        try? modelContext.save()
    }

    private func nextClusterID() -> Int {
        (allClusters().map(\.clusterID).max() ?? -1) + 1
    }

    private func removeFromCluster(clusterID: Int, vec: [Float], faceID: String) {
        guard let c = cluster(clusterID) else { return }
        guard let sum = ClipMath.decodeHalf(c.sum),
              let updated = FaceClustering.removing(vec, fromSum: sum, count: c.count) else {
            // 最後の 1 顔（または sum 破損）＝クラスタごと削除。
            modelContext.delete(c)
            return
        }
        c.sum = ClipMath.encodeHalf(updated.sum)
        c.count = updated.count
        if c.coverFaceID == faceID {
            // 代表顔が抜けたら未設定に戻し、読み出し時の自動選択（お気に入り優先→先頭）に任せる。
            c.coverFaceID = nil
        }
    }

    private func addToCluster(clusterID: Int, vec: [Float], faceID: String) {
        if let c = cluster(clusterID) {
            if let sum = ClipMath.decodeHalf(c.sum) {
                let updated = FaceClustering.adding(vec, toSum: sum, count: c.count)
                c.sum = ClipMath.encodeHalf(updated.sum)
                c.count = updated.count
            } else {
                c.count += 1
            }
        } else {
            let seeded = FaceClustering.adding(vec, toSum: [Float](repeating: 0, count: vec.count), count: 0)
            modelContext.insert(PersonCluster(
                clusterID: clusterID, sum: ClipMath.encodeHalf(seeded.sum), count: seeded.count,
                name: nil, coverFaceID: nil))
        }
    }

    func rename(clusterID: Int, name: String?) {
        guard let c = cluster(clusterID) else { return }
        c.name = (name?.isEmpty == true) ? nil : name
        try? modelContext.save()
    }

    /// 全消去（再スキャン用）。
    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        try? modelContext.save()
    }
}
