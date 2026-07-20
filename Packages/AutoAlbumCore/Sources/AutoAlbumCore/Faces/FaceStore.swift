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
        // FaceCorrection は追加テーブル（ADR-45）＝加算的マイグレーション（既存の顔データは保持）。
        let schema = Schema([DetectedFace.self, PersonCluster.self, ScannedPhoto.self, FaceCorrection.self])
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
    /// この品質未満の顔はクラスタへ割り当てない（ぼけ顔・横顔が重心を汚さない・ADR-45）。
    private static let qualityFloor: Float = 0.15
    /// 負例エグゼンプラの上限（コスト有界化・新しい順に保持）。
    private static let maxNegatives = 400

    /// 逐次クラスタリング状態のインメモリキャッシュ。以前は写真1枚のスキャンごとに
    /// 全クラスタを fetch → Float16 復元しており、人物が増えるほど背景スキャンが遅くなる
    /// 構造だった（O(クラスタ数)/枚）。recordScan 間で再利用し、重心を変える操作
    /// （reassign/reset）で無効化する。
    private var clusteringCache: FaceClustering?
    /// 負例エグゼンプラ（修正ジャーナル由来・ADR-45）のインメモリキャッシュ。
    /// clusteringCache と同じライフサイクルで再利用し、修正追加で無効化する。
    private var negativesCache: [FaceClustering.NegativePair]?

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

    /// 全スキャン済み写真の refKey → 顔数（実測）。AI アルバムの「人が写っていない」判定に使う。
    func scannedFaceCounts() -> [String: Int] {
        let markers = (try? modelContext.fetch(FetchDescriptor<ScannedPhoto>())) ?? []
        var out: [String: Int] = [:]
        out.reserveCapacity(markers.count)
        for m in markers { out[m.refKey] = m.faceCount }
        return out
    }
    func faceCount() -> Int { (try? modelContext.fetchCount(FetchDescriptor<DetectedFace>())) ?? 0 }

    /// 1 写真の顔数（実測）。未スキャンは nil（＝「まだ数えていない」と「顔 0」を区別できる）。
    /// フル画像ビューの表示用（何人写っているか）。
    func faceCount(refKey: String) -> Int? {
        let key = refKey
        var d = FetchDescriptor<ScannedPhoto>(predicate: #Predicate { $0.refKey == key })
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first?.faceCount
    }

    // MARK: - 記録＋逐次クラスタリング

    /// 複数写真分の検出結果をまとめて記録する（T3: save をバッチ 1 回に）。
    /// 従来は写真ごとに save しており、13k 枚のスキャンで 13k 回の SQLite save が発生していた。
    func recordScans(_ batch: [(refKey: String, faces: [DetectedFaceSignal])]) {
        for entry in batch {
            recordScan(refKey: entry.refKey, faces: entry.faces, deferSave: true)
        }
        try? modelContext.save()
    }

    /// 1 写真分の検出結果を記録する（顔行＋マーカー）。各顔を既存クラスタへ逐次割り当てる。
    func recordScan(refKey: String, faces: [DetectedFaceSignal], deferSave: Bool = false) {
        // すでに記録済みなら二重記録しない。
        let key = refKey
        var marker = FetchDescriptor<ScannedPhoto>(predicate: #Predicate { $0.refKey == key })
        marker.fetchLimit = 1
        if (try? modelContext.fetch(marker).first) != nil { return }

        modelContext.insert(ScannedPhoto(refKey: refKey, faceCount: faces.count))

        if !faces.isEmpty {
            var clustering = loadClustering()
            let negatives = loadNegatives()
            for (i, face) in faces.enumerated() {
                guard let vec = ClipMath.decodeHalf(face.embedding) else { continue }
                let faceID = "\(refKey)#\(i)"
                // 品質重み＋負例つき割り当て（ADR-45）。フロア未満は -1（未割当・重心を汚さない）。
                let cid = clustering.assign(faceID: faceID, embedding: vec,
                                            quality: face.quality, negatives: negatives)
                modelContext.insert(DetectedFace(
                    faceID: faceID, refKey: refKey,
                    bx: face.boundingBox.origin.x, by: face.boundingBox.origin.y,
                    bw: face.boundingBox.size.width, bh: face.boundingBox.size.height,
                    embedding: face.embedding, quality: Double(face.quality), clusterID: cid))
            }
            persist(clustering)
            clusteringCache = clustering   // 次の写真はここから逐次継続（全復元しない）
        }
        if !deferSave { try? modelContext.save() }
    }

    /// 永続化済みクラスタを `FaceClustering` に復元する（重心・件数・代表顔まで）。
    /// インメモリキャッシュがあればそれを使う（recordScan ごとの全復元を避ける）。
    private func loadClustering() -> FaceClustering {
        if let cached = clusteringCache { return cached }
        var seed: [FaceClustering.Cluster] = []
        for r in allClusters() {
            guard let sum = ClipMath.decodeHalf(r.sum) else { continue }
            seed.append(FaceClustering.Cluster(
                id: r.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: r.count, faceIDs: r.coverFaceID.map { [$0] } ?? []))
        }
        return FaceClustering(threshold: Self.clusterThreshold, qualityFloor: Self.qualityFloor,
                              seedClusters: seed)
    }

    /// 修正ジャーナル（ADR-45）から負例エグゼンプラを復元する。埋め込みキーなので
    /// 再スキャン・モデル入れ替えを跨いで効く。新しい順に上限まで。
    private func loadNegatives() -> [FaceClustering.NegativePair] {
        if let cached = negativesCache { return cached }
        var d = FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.wrongEmbedding != nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = Self.maxNegatives
        let rows = (try? modelContext.fetch(d)) ?? []
        let pairs: [FaceClustering.NegativePair] = rows.compactMap { r in
            guard let wrong = r.wrongEmbedding,
                  let fe = ClipMath.decodeHalf(r.faceEmbedding),
                  let we = ClipMath.decodeHalf(wrong) else { return nil }
            return FaceClustering.NegativePair(
                faceCentroid: FaceClustering.normalized(fe),
                wrongCentroid: FaceClustering.normalized(we))
        }
        negativesCache = pairs
        return pairs
    }

    /// 修正ジャーナルの件数（Developer Options / 診断用）。
    func correctionCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<FaceCorrection>())) ?? 0
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

    /// 全スキャン済み写真の refKey → 人物表示名（自動アルバム生成の people 付与用）。
    /// 「人物」とみなせるクラスタ（minFaces 以上）のみ。未命名は "Person N"。
    func peopleNamesByRefKey(minFaces: Int) -> [String: [String]] {
        let clusters = allClusters().filter { $0.count >= minFaces }
        var nameByCluster: [Int: String] = [:]
        for c in clusters { nameByCluster[c.clusterID] = c.name ?? "Person \(c.clusterID + 1)" }
        guard !nameByCluster.isEmpty else { return [:] }
        let faces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
        var out: [String: [String]] = [:]
        for f in faces {
            guard let name = nameByCluster[f.clusterID] else { continue }
            if out[f.refKey]?.contains(name) != true {
                out[f.refKey, default: []].append(name)
            }
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
        let quality = Float(face.quality)

        // ADR-45: 「この顔はこの人ではない」を負例として記録（付け替え元に**他の顔がいた**とき、
        // ＝ 誤って一緒にされていたときだけ）。単独クラスタからの分離は誤りの信号ではないので除外。
        if let oldCluster = cluster(oldCID), oldCluster.count >= 2,
           let oldSum = ClipMath.decodeHalf(oldCluster.sum) {
            recordCorrection(kind: "reassign", faceEmbedding: face.embedding,
                             wrongEmbedding: ClipMath.encodeHalf(oldSum))
        }

        removeFromCluster(clusterID: oldCID, vec: vec, quality: quality, faceID: faceID)
        let targetCID = toClusterID ?? nextClusterID()
        addToCluster(clusterID: targetCID, vec: vec, quality: quality, faceID: faceID)
        face.clusterID = targetCID
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次回に再構築）
    }

    /// 修正ジャーナルへ 1 件追記（ADR-45）。負例キャッシュを無効化する。
    private func recordCorrection(kind: String, faceEmbedding: Data, wrongEmbedding: Data?) {
        modelContext.insert(FaceCorrection(
            id: UUID().uuidString, kind: kind,
            faceEmbedding: faceEmbedding, wrongEmbedding: wrongEmbedding, createdAt: Date()))
        negativesCache = nil
    }

    private func nextClusterID() -> Int {
        (allClusters().map(\.clusterID).max() ?? -1) + 1
    }

    private func removeFromCluster(clusterID: Int, vec: [Float], quality: Float, faceID: String) {
        guard let c = cluster(clusterID) else { return }
        guard let sum = ClipMath.decodeHalf(c.sum),
              let updated = FaceClustering.removing(vec, fromSum: sum, count: c.count, quality: quality) else {
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

    private func addToCluster(clusterID: Int, vec: [Float], quality: Float, faceID: String) {
        if let c = cluster(clusterID) {
            if let sum = ClipMath.decodeHalf(c.sum) {
                let updated = FaceClustering.adding(vec, toSum: sum, count: c.count, quality: quality)
                c.sum = ClipMath.encodeHalf(updated.sum)
                c.count = updated.count
            } else {
                c.count += 1
            }
        } else {
            let seeded = FaceClustering.adding(vec, toSum: [Float](repeating: 0, count: vec.count),
                                               count: 0, quality: quality)
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

    /// 人物クラスタ src を dst に統合する（同一人物が 2 クラスタに割れたときの修正）。
    /// src の顔を全て dst へ付け替え、重心（sum/count）を合流し、src のクラスタ行を削除する。
    /// 名前・代表顔は dst を優先し、dst が未設定のときだけ src から引き継ぐ。
    func mergeClusters(from srcID: Int, into dstID: Int) {
        guard srcID != dstID, let src = cluster(srcID), let dst = cluster(dstID) else { return }
        // 顔を一括付け替え（DetectedFace.clusterID）。
        for f in faces(inCluster: srcID) { f.clusterID = dstID }
        // 重心（生合計と件数）を合流。
        if let sSum = ClipMath.decodeHalf(src.sum), let dSum = ClipMath.decodeHalf(dst.sum) {
            let merged = FaceClustering.merging(sumA: dSum, countA: dst.count,
                                                sumB: sSum, countB: src.count)
            dst.sum = ClipMath.encodeHalf(merged.sum)
            dst.count = merged.count
        } else {
            dst.count += src.count
        }
        if (dst.name?.isEmpty ?? true), let n = src.name, !n.isEmpty { dst.name = n }
        if dst.coverFaceID == nil { dst.coverFaceID = src.coverFaceID }
        // ADR-45: 統合（＝同一人物）を記録（負例ではないので wrongEmbedding は nil）。将来の
        // モデル入れ替え時の replay 材料。src の重心埋め込みを faceEmbedding として残す。
        if let sSum = ClipMath.decodeHalf(src.sum) {
            recordCorrection(kind: "merge", faceEmbedding: ClipMath.encodeHalf(sSum), wrongEmbedding: nil)
        }
        modelContext.delete(src)
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次スキャンで再構築）
    }

    /// 全消去（再スキャン用）。
    /// ⚠️ 修正ジャーナル（FaceCorrection）は**消さない**（ADR-45）。負例は埋め込みキーなので、
    /// 再スキャン中の割り当てで自動的に再適用され、既知の誤りが再発しない。
    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        try? modelContext.save()
        clusteringCache = nil
        negativesCache = nil   // 次スキャンで DB から読み直す（ジャーナルは残存）
    }

    /// 修正ジャーナルも含めた完全消去（Developer Options の「学習もリセット」用）。
    func resetIncludingCorrections() {
        try? modelContext.delete(model: FaceCorrection.self)
        reset()
    }
}
