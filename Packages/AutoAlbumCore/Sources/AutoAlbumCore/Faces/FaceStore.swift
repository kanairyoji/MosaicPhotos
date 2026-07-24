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
    /// 校正済みしきい値のキャッシュ（B1・ADR-46）。修正追加で無効化。
    private var thresholdCache: Float?

    /// ユーザー修正から校正したしきい値（サンプル不足なら既定 0.45）。
    func calibratedThreshold() -> Float {
        if let cached = thresholdCache { return cached }
        let rows = (try? modelContext.fetch(FetchDescriptor<FaceCorrection>())) ?? []
        var positive: [Float] = []
        var negative: [Float] = []
        for r in rows {
            guard let sim = r.similarity else { continue }
            switch r.kind {
            case "merge", "confirm":     positive.append(Float(sim))
            case "reassign", "notSame":  negative.append(Float(sim))
            default: break
            }
        }
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative,
                                                    fallback: Self.clusterThreshold)
        thresholdCache = t
        if t != Self.clusterThreshold {
            Self.log.info("faces: calibrated threshold \(t) (pos=\(positive.count) neg=\(negative.count))")
        }
        return t
    }

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
        let anchors = anchorsByCluster()
        var seed: [FaceClustering.Cluster] = []
        for r in allClusters() {
            guard let sum = ClipMath.decodeHalf(r.sum) else { continue }
            seed.append(FaceClustering.Cluster(
                id: r.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: r.count, faceIDs: r.coverFaceID.map { [$0] } ?? [],
                prototypes: anchors[r.clusterID] ?? []))
        }
        return FaceClustering(threshold: calibratedThreshold(), qualityFloor: Self.qualityFloor,
                              seedClusters: seed)
    }

    /// クラスタごとのアンカー（確認済みの顔の正規化済み埋め込み・新しい順に最大 5）。
    /// B3 マルチプロトタイプ: 割り当ては「重心 or アンカーとの最大類似」になる。
    private func anchorsByCluster(limitPerCluster: Int = 5) -> [Int: [[Float]]] {
        let confirmed = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { $0.confirmedAt != nil },
            sortBy: [SortDescriptor(\.confirmedAt, order: .reverse)]))) ?? []
        var out: [Int: [[Float]]] = [:]
        for f in confirmed {
            guard (out[f.clusterID]?.count ?? 0) < limitPerCluster,
                  let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            out[f.clusterID, default: []].append(FaceClustering.normalized(vec))
        }
        return out
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
        var pairs: [FaceClustering.NegativePair] = []
        for r in rows {
            guard let wrong = r.wrongEmbedding,
                  let fe = ClipMath.decodeHalf(r.faceEmbedding),
                  let we = ClipMath.decodeHalf(wrong) else { continue }
            let a = FaceClustering.normalized(fe)
            let b = FaceClustering.normalized(we)
            pairs.append(FaceClustering.NegativePair(faceCentroid: a, wrongCentroid: b))
            if r.kind == "notSame" {
                // 「この 2 人は別人」（統合拒否）は対称＝双方向の負例にする。
                pairs.append(FaceClustering.NegativePair(faceCentroid: b, wrongCentroid: a))
            }
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

    /// この写真に写っている**指定クラスタの**顔矩形（Vision 正規化・原点左下）。
    /// 人物アルバムで「どの顔をこの人物として認識したか」をチェックする用途なので、
    /// 同じ写真の複数の顔が同一クラスタに入っていても（混入の疑い）、
    /// **重心に最も近い 1 顔だけ**を返す（全部に枠が付くとどれがこの人物か
    /// 分からず目的を果たせない＝実フィードバック）。
    func faceBoxes(refKey: String, clusterID: Int) -> [CGRect] {
        let members = faces(inPhoto: refKey).filter { $0.clusterID == clusterID }
        guard members.count > 1 else {
            return members.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
        }
        var best: (face: DetectedFace, sim: Float)?
        if let c = cluster(clusterID), let sum = ClipMath.decodeHalf(c.sum) {
            let centroid = FaceClustering.normalized(sum)
            for f in members {
                guard let v = ClipMath.decodeHalf(f.embedding) else { continue }
                let sim = FaceClustering.dot(FaceClustering.normalized(v), centroid)
                if best == nil || sim > best!.sim { best = (f, sim) }
            }
        }
        let chosen = best?.face ?? members[0]
        return [CGRect(x: chosen.bx, y: chosen.by, width: chosen.bw, height: chosen.bh)]
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
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(oldSum))
            recordCorrection(kind: "reassign", faceEmbedding: face.embedding,
                             wrongEmbedding: ClipMath.encodeHalf(oldSum), similarity: sim)
        }
        // ADR-46: 付け替え先を**ユーザーが選んだ**＝「この顔はこの人」という確認。
        // 正例として記録し、アンカー（マルチプロトタイプ）にする。
        if let toClusterID, let target = cluster(toClusterID),
           let targetSum = ClipMath.decodeHalf(target.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(targetSum))
            recordCorrection(kind: "confirm", faceEmbedding: face.embedding,
                             wrongEmbedding: nil, similarity: sim)
            face.confirmedAt = Date()
        }

        removeFromCluster(clusterID: oldCID, vec: vec, quality: quality, faceID: faceID)
        let targetCID = toClusterID ?? nextClusterID()
        addToCluster(clusterID: targetCID, vec: vec, quality: quality, faceID: faceID)
        face.clusterID = targetCID
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次回に再構築）
    }

    /// 「この写真はこの人？」に **はい**（A2・ADR-46）。顔を確認済み（アンカー）にし、
    /// 正例（顔×所属クラスタ重心の類似）をしきい値校正の材料として記録する。
    func confirmFace(faceID: String) {
        guard let face = face(byID: faceID),
              let vec = ClipMath.decodeHalf(face.embedding),
              let c = cluster(face.clusterID),
              let sum = ClipMath.decodeHalf(c.sum) else { return }
        let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                     FaceClustering.normalized(sum))
        recordCorrection(kind: "confirm", faceEmbedding: face.embedding,
                         wrongEmbedding: nil, similarity: sim)
        face.confirmedAt = Date()
        try? modelContext.save()
    }

    /// 「同じ人物？」に **いいえ**（A1・ADR-46）。2 クラスタを「別人」として記録する。
    /// 以後この対は (1) 統合サジェストに出さない、(2) 双方向の負例として合流を拒否する。
    func markNotSamePerson(clusterA: Int, clusterB: Int) {
        guard let a = cluster(clusterA), let b = cluster(clusterB),
              let aSum = ClipMath.decodeHalf(a.sum), let bSum = ClipMath.decodeHalf(b.sum) else { return }
        let sim = FaceClustering.dot(FaceClustering.normalized(aSum),
                                     FaceClustering.normalized(bSum))
        recordCorrection(kind: "notSame", faceEmbedding: ClipMath.encodeHalf(aSum),
                         wrongEmbedding: ClipMath.encodeHalf(bSum), similarity: sim)
        try? modelContext.save()
    }

    /// 修正ジャーナルへ 1 件追記（ADR-45/46）。負例・校正キャッシュを無効化する。
    private func recordCorrection(kind: String, faceEmbedding: Data, wrongEmbedding: Data?,
                                  similarity: Float? = nil) {
        modelContext.insert(FaceCorrection(
            id: UUID().uuidString, kind: kind,
            faceEmbedding: faceEmbedding, wrongEmbedding: wrongEmbedding,
            similarity: similarity.map(Double.init), createdAt: Date()))
        negativesCache = nil
        thresholdCache = nil
        clusteringCache = nil   // しきい値が変わり得るため次スキャンで再構築
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
        // ADR-45/46: 統合（＝同一人物）を正例として記録。類似度は**統合前**の重心同士で測る
        //（統合後の dst.sum には src が混ざり、値が不当に高くなるため）。
        if let sSum = ClipMath.decodeHalf(src.sum), let dSumBefore = ClipMath.decodeHalf(dst.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(sSum),
                                         FaceClustering.normalized(dSumBefore))
            recordCorrection(kind: "merge", faceEmbedding: ClipMath.encodeHalf(sSum),
                             wrongEmbedding: nil, similarity: sim)
        }
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
        modelContext.delete(src)
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次スキャンで再構築）
    }

    // MARK: - 人物レビュー（A1/A2・ADR-46）

    /// レビューカードの生成。**判断が割れるケースだけ**を選ぶ（アクティブラーニング）:
    /// - A1 統合サジェスト: 重心類似が「合流の一歩手前」（しきい値−0.10 〜 しきい値）の
    ///   クラスタ対。「別人」と記録済みの対は出さない。
    /// - A2 境界の顔: クラスタ内で重心類似が最も低い（しきい値＋0.10 未満）未確認の顔
    ///   ＝混入している別人が最も出やすい位置。
    /// - Parameter excluding: 出題済み（既定回数見せたが答えられなかった）カード ID。
    ///   同じ質問を繰り返さず、次点の候補で埋める（実フィードバック対応）。
    func reviewItems(minFaces: Int, limit: Int = 30,
                     excluding: Set<String> = []) -> [FaceReviewItem] {
        let thr = calibratedThreshold()
        let clusters = allClusters().filter { $0.count >= minFaces }
        guard clusters.count >= 1 else { return [] }

        // 重心（正規化）と表示用の代表顔を用意。
        var centroid: [Int: [Float]] = [:]
        var coverFace: [Int: PersonInfo.Face] = [:]
        var name: [Int: String] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
            // 未命名は空（UI は名前ラベルを出さない。"Person N" は誰か分からず判断の助けにならない）。
            name[c.clusterID] = (c.name?.isEmpty == false) ? (c.name ?? "") : ""
            let members = faces(inCluster: c.clusterID)
            let cover = c.coverFaceID.flatMap { fid in members.first { $0.faceID == fid } }
                ?? members.first
            if let f = cover {
                coverFace[c.clusterID] = PersonInfo.Face(
                    faceID: f.faceID, refKey: f.refKey,
                    boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh))
            }
        }

        // 「別人」と記録済みの対（重心埋め込みで照合＝ID の揺れに強い）。
        let notSameRows = ((try? modelContext.fetch(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.kind == "notSame" }))) ?? []).compactMap {
            row -> ([Float], [Float])? in
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        func isMarkedNotSame(_ a: [Float], _ b: [Float]) -> Bool {
            for (ra, rb) in notSameRows {
                if (FaceClustering.dot(a, ra) >= 0.9 && FaceClustering.dot(b, rb) >= 0.9)
                    || (FaceClustering.dot(a, rb) >= 0.9 && FaceClustering.dot(b, ra) >= 0.9) {
                    return true
                }
            }
            return false
        }

        var items: [FaceReviewItem] = []

        // A1: 統合サジェスト（類似度の高い対から）。
        let ids = clusters.map(\.clusterID)
        var mergeCandidates: [(a: Int, b: Int, sim: Float)] = []
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                guard let ca = centroid[ids[i]], let cb = centroid[ids[j]] else { continue }
                let sim = FaceClustering.dot(ca, cb)
                guard sim >= thr - 0.10, sim < thr, !isMarkedNotSame(ca, cb) else { continue }
                mergeCandidates.append((ids[i], ids[j], sim))
            }
        }
        for cand in mergeCandidates.sorted(by: { $0.sim > $1.sim }) {
            guard items.count < limit else { break }
            guard let fa = coverFace[cand.a], let fb = coverFace[cand.b] else { continue }
            let item = FaceReviewItem.samePerson(
                aClusterID: cand.a, aName: name[cand.a] ?? "", aFace: fa,
                bClusterID: cand.b, bName: name[cand.b] ?? "", bFace: fb,
                similarity: cand.sim)
            if excluding.contains(item.id) { continue }
            items.append(item)
        }

        // A2: 境界の顔（クラスタごとに最大 2・類似が低い順）。命名済みクラスタを優先。
        let ordered = clusters.sorted {
            (($0.name?.isEmpty == false) ? 0 : 1, -$0.count) < (($1.name?.isEmpty == false) ? 0 : 1, -$1.count)
        }
        for c in ordered {
            guard items.count < limit, let cen = centroid[c.clusterID] else { continue }
            var boundary: [(face: DetectedFace, sim: Float)] = []
            for f in faces(inCluster: c.clusterID) where f.confirmedAt == nil {
                guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
                let sim = FaceClustering.dot(FaceClustering.normalized(vec), cen)
                if sim < thr + 0.10 { boundary.append((f, sim)) }
            }
            guard let cover = coverFace[c.clusterID] else { continue }
            var perCluster = 0
            for entry in boundary.sorted(by: { $0.sim < $1.sim }) {
                guard items.count < limit, perCluster < 2 else { break }
                // 未命名（Person N）は name=nil ＝ UI が「代表の顔と並べて比較」カードにする
                //（名前を出しても誰か分からず答えられない・実フィードバック）。
                // 境界顔自身が代表と同一（1 枚だけのケース等）は比較にならないので出さない。
                let displayName = (c.name?.isEmpty == false) ? c.name : nil
                if displayName == nil && cover.faceID == entry.face.faceID { continue }
                let item = FaceReviewItem.isThisPerson(
                    face: PersonInfo.Face(faceID: entry.face.faceID, refKey: entry.face.refKey,
                                          boundingBox: CGRect(x: entry.face.bx, y: entry.face.by,
                                                              width: entry.face.bw, height: entry.face.bh)),
                    clusterID: c.clusterID, name: displayName,
                    coverFace: cover,
                    similarity: entry.sim)
                if excluding.contains(item.id) { continue }   // 出題済み → 次点で埋める
                items.append(item)
                perCluster += 1
            }
        }
        return items
    }

    // MARK: - 制約付き再クラスタリング（B2・ADR-46）

    /// 全顔を**制約つきで**割り当て直す。逐次クラスタリングの順序依存（早い段階の誤りを
    /// 後から直せない）を断つ夜間ジョブ。
    /// - 種クラスタ: 命名済み or 確認顔ありのクラスタは **ID・名前・代表を保持**し、
    ///   確認顔（アンカー）を must-link として先に固定する。
    /// - 残りの顔を**品質降順**に割り当て（高品質の顔が先にクラスタの核を作る）。
    ///   しきい値は校正済み・負例も適用。
    /// 戻り値: (クラスタ数, 割り当てが変わった顔数)。
    func rebuildClusters() -> (clusters: Int, moved: Int) {
        let allFaces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
        guard !allFaces.isEmpty else { return (0, 0) }
        let thr = calibratedThreshold()
        let negatives = loadNegatives()
        let existing = allClusters()
        let maxExistingID = existing.map(\.clusterID).max() ?? -1

        // 1) 種クラスタ（命名済み or 確認顔あり）: アンカーだけから重心を作り直す。
        //    アンカーが無い（名前のみ）の種は現重心を 1 票として方向を維持する。
        var seeds: [FaceClustering.Cluster] = []
        var seedIDs = Set<Int>()
        var confirmedFaceIDs = Set<String>()
        for c in existing {
            let members = faces(inCluster: c.clusterID)
            let anchors = members.filter { $0.confirmedAt != nil }
            let isSeed = (c.name?.isEmpty == false) || !anchors.isEmpty
            guard isSeed else { continue }
            var sum: [Float] = []
            var count = 0
            var protos: [[Float]] = []
            for a in anchors {
                guard let vec = ClipMath.decodeHalf(a.embedding) else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: vec.count) }
                let added = FaceClustering.adding(vec, toSum: sum, count: count,
                                                  quality: Float(a.quality))
                sum = added.sum
                count = added.count
                protos.append(FaceClustering.normalized(vec))
                confirmedFaceIDs.insert(a.faceID)
            }
            if sum.isEmpty {
                guard let cur = ClipMath.decodeHalf(c.sum) else { continue }
                sum = FaceClustering.normalized(cur)   // 現重心を 1 票（方向のみ維持）
                count = 1
            }
            seeds.append(FaceClustering.Cluster(
                id: c.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: count, faceIDs: [], prototypes: protos))
            seedIDs.insert(c.clusterID)
        }

        // 2) 残りの顔を品質降順に割り当て（新規クラスタ ID は既存の最大より先から）。
        var clustering = FaceClustering(threshold: thr, qualityFloor: Self.qualityFloor,
                                        seedClusters: seeds, minimumNextID: maxExistingID + 1)
        let pending = allFaces.filter { !confirmedFaceIDs.contains($0.faceID) }
            .sorted { $0.quality > $1.quality }
        var newAssignment: [String: Int] = [:]
        for f in pending {
            guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            newAssignment[f.faceID] = clustering.assign(
                faceID: f.faceID, embedding: vec,
                quality: Float(f.quality), negatives: negatives)
        }

        // 3) 書き戻し: 顔の clusterID（確認顔は種のまま）・種以外の旧クラスタ行は削除して再作成。
        var moved = 0
        for f in allFaces {
            let newID = confirmedFaceIDs.contains(f.faceID) ? f.clusterID
                : (newAssignment[f.faceID] ?? FaceClustering.unassigned)
            if f.clusterID != newID { moved += 1 }
            f.clusterID = newID
        }
        for c in existing where !seedIDs.contains(c.clusterID) {
            modelContext.delete(c)
        }
        persist(clustering)
        try? modelContext.save()
        clusteringCache = nil
        Self.log.info("faces: rebuild — clusters=\(clustering.clusters.count) moved=\(moved) thr=\(thr)")
        return (clustering.clusters.count, moved)
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
