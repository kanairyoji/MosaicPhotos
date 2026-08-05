import PerceptionCore
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
    static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Faces")

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        // FaceCorrection は追加テーブル（ADR-45）＝加算的マイグレーション（既存の顔データは保持）。
        let schema = Schema([DetectedFace.self, PersonCluster.self, ScannedPhoto.self, FaceCorrection.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return resilientModelContainer(name: "FacesV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    /// 同一クラスタとみなすコサイン下限（facenet 正規化埋め込みの目安）。
    /// クラスタリング既定しきい値。サイズ適応マージン併用時の FG-NET 実測（ADR-58）で
    /// F1 最大となった 0.50（thr0.50＋margin0.05＋sizeMax0.10 で F1 0.589・純度 0.879）。
    /// 校正（FaceCalibration）が上書きし得る。
    static let clusterThreshold: Float = 0.50
    /// マージンゲート幅（ADR-57・1 位/2 位の差がこれ未満なら合流しない）。
    static let assignMargin: Float = 0.05
    /// サイズ適応マージンの最大上乗せ（ADR-58・小/新クラスタの合流を厳しくする）。
    static let sizeAdaptiveMarginMax: Float = 0.10
    /// **サイズ適応マージンの免除**（ADR-68）。サイズ適応マージン（ADR-58）は「小クラスタが
    /// 兄弟を吸い込むのを防ぐ」ためだが、家族アルバムでは小クラスタの大半が*同じ人の断片*なので
    /// 合流を止めて分裂を量産していた（実ライブラリで 3 人 → 2,000 人超）。近くに「別人らしい
    /// 競合」がいないときだけ上乗せを免除する。
    /// ⚠️ マージンゲート側の免除は**不採用**（サイズ免除だけで利得が出揃い、FG-NET 全体では
    /// わずかに悪化したため）。
    static let rivalAwareSizeMargin = true
    /// 免除を効かせる上限人数（成熟クラスタ数）。**少人数ライブラリ限定**にする。
    /// 免除の正否はライブラリの人数で反転する（計測事実）: 無制限だと LFW（901人）で
    /// F1 0.895→0.843 と退行するが、10 人未満に限れば 0.889（−0.006）に収まり、
    /// 家族シナリオの利得（分裂 4.7→2.0・純度 0.862→0.970）は全て保たれる。
    static let rivalAwareSizeMarginMaxPeople = 10
    /// 「競合が似ている＝同一人物」と判定するバーの上乗せ（実効 0.50+0.20=0.70）。
    /// 緩いと別人まで似ている扱いになり純度が落ちる（掃引で決定・face-accuracy.md 2026-08-05）。
    static let rivalAlikeMargin: Float = 0.20
    /// **サイズ加算の積み上がりを止める**（ADR-68 追補）。しきい値は校正で上がり得るので、
    /// そこへサイズ適応マージンが乗ると実効しきい値が跳ね上がる（実機で 0.60+0.10=0.70）。
    /// 少人数ライブラリでは加算しない＝実効しきい値を素のしきい値で頭打ちにする。
    /// FG-NET 家族5人で分裂 3.6→2.4・純度 0.911→0.884・F1 0.718→0.750。
    static let capEffectiveThresholdWhenFewPeople = true
    /// 上限を効かせる上限人数（サイズ免除と同じ母数・同じ理由で少人数限定）。
    /// 無制限にすると LFW（901人）で F1 0.906→0.873 と退行する。
    static let effectiveThresholdCapMaxPeople = 10
    /// この品質未満の顔はクラスタへ割り当てない（ぼけ顔・横顔が重心を汚さない・ADR-45）。
    /// 品質フロア（face-info-expansion 優先度 2: 0.15 → 0.40）。ぼけ顔・横顔（品質キャップ済み）を
    /// クラスタへ入れず重心汚染を防ぐ。フロア未満も DetectedFace としては記録される（顔数・枠表示用）。
    static let qualityFloor: Float = 0.40
    /// 共起 notSame: 2 クラスタが同じ写真にこれ以上の回数一緒に写っていたら「別人」とみなし
    /// 統合サジェストを出さない（同一人物は 1 枚の写真に 1 回しか写れない・偶発の誤検出は許容）。
    static let coOccurrenceNotSame = 3
    /// 負例エグゼンプラの上限（コスト有界化・新しい順に保持）。
    static let maxNegatives = 400

    /// 逐次クラスタリング状態のインメモリキャッシュ。以前は写真1枚のスキャンごとに
    /// 全クラスタを fetch → Float16 復元しており、人物が増えるほど背景スキャンが遅くなる
    /// 構造だった（O(クラスタ数)/枚）。recordScan 間で再利用し、重心を変える操作
    /// （reassign/reset）で無効化する。
    var clusteringCache: FaceClustering?
    /// 負例エグゼンプラ（修正ジャーナル由来・ADR-45）のインメモリキャッシュ。
    /// clusteringCache と同じライフサイクルで再利用し、修正追加で無効化する。
    var negativesCache: [FaceClustering.NegativePair]?
    /// 校正済みしきい値のキャッシュ（B1・ADR-46）。修正追加で無効化。
    var thresholdCache: Float?

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

    func cluster(_ clusterID: Int) -> PersonCluster? {
        let cid = clusterID
        var d = FetchDescriptor<PersonCluster>(predicate: #Predicate { $0.clusterID == cid })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    func allClusters() -> [PersonCluster] {
        (try? modelContext.fetch(FetchDescriptor<PersonCluster>())) ?? []
    }

    /// 代表顔の自動選択スコア: 品質を軸に、笑顔（+0.3）と顔の大きさ（bw・最大+0.2）で加点。
    /// ユーザーが代表を指定済み（coverFaceID）の場合は呼ばれない。
    static func bestCoverFace(_ faces: [DetectedFace]) -> DetectedFace? {
        faces.max { coverScore($0) < coverScore($1) }
    }

    static func coverScore(_ f: DetectedFace) -> Double {
        f.quality + (f.hasSmile == true ? 0.3 : 0) + min(f.bw, 1.0) * 0.2
    }

    func face(byID faceID: String) -> DetectedFace? {
        let fid = faceID
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.faceID == fid })
        d.fetchLimit = 1
        return try? modelContext.fetch(d).first
    }

    func faces(inCluster clusterID: Int) -> [DetectedFace] {
        let cid = clusterID
        return (try? modelContext.fetch(
            FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid }))) ?? []
    }

    func faces(inPhoto refKey: String) -> [DetectedFace] {
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
            // 同一写真 cannot-link: 1 枚の写真に同じ人物は 1 回しか写らないため、
            // この写真で既に使ったクラスタへは後続の顔を入れない（兄弟・家族写真の混入対策）。
            var usedClusters = Set<Int>()
            for (i, face) in faces.enumerated() {
                guard let vec = ClipMath.decodeHalf(face.embedding) else { continue }
                let faceID = "\(refKey)#\(i)"
                // 品質重み＋負例つき割り当て（ADR-45）。フロア未満は -1（未割当・重心を汚さない）。
                var cid = clustering.assign(faceID: faceID, embedding: vec,
                                            quality: face.quality, negatives: negatives,
                                            excludedClusterIDs: usedClusters)
                // 第2パス（ADR-66・recall 回復）: フロア未満で未割当なら、重心を汚さず最寄り人物へ
                // membership だけ割り当てる（クラスタ形成前なら未割当のまま＝夜間 rebuild が拾う）。
                if cid < 0 && face.quality < Self.qualityFloor {
                    cid = clustering.assignMembershipOnly(faceID: faceID, embedding: vec,
                                                          excludedClusterIDs: usedClusters)
                }
                if cid >= 0 { usedClusters.insert(cid) }
                modelContext.insert(DetectedFace(
                    faceID: faceID, refKey: refKey,
                    bx: face.boundingBox.origin.x, by: face.boundingBox.origin.y,
                    bw: face.boundingBox.size.width, bh: face.boundingBox.size.height,
                    embedding: face.embedding, quality: Double(face.quality), clusterID: cid,
                    hasSmile: face.hasSmile, captureDate: face.captureDate))
            }
            persist(clustering)
            clusteringCache = clustering   // 次の写真はここから逐次継続（全復元しない）
        }
        if !deferSave { try? modelContext.save() }
    }

    /// 永続化済みクラスタを `FaceClustering` に復元する（重心・件数・代表顔まで）。
    /// インメモリキャッシュがあればそれを使う（recordScan ごとの全復元を避ける）。
    func loadClustering() -> FaceClustering {
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
        var clustering = FaceClustering(threshold: calibratedThreshold(), qualityFloor: Self.qualityFloor,
                                        seedClusters: seed)
        clustering.assignMargin = Self.assignMargin   // マージンゲート（ADR-57）
        clustering.sizeAdaptiveMarginMax = Self.sizeAdaptiveMarginMax   // サイズ適応（ADR-58）
        // サイズ適応マージンの免除（ADR-68・少人数ライブラリ限定）
        clustering.rivalAwareSizeMargin = Self.rivalAwareSizeMargin
        clustering.rivalAwareSizeMarginMaxPeople = Self.rivalAwareSizeMarginMaxPeople
        clustering.rivalAlikeMargin = Self.rivalAlikeMargin
        // 実効しきい値の頭打ち（ADR-68 追補・少人数ライブラリ限定）。しきい値は校正で
        // 上がり得るので、そこへサイズ加算が乗って跳ね上がるのを止める。
        if Self.capEffectiveThresholdWhenFewPeople {
            clustering.effectiveThresholdCap = clustering.threshold
            clustering.effectiveThresholdCapMaxPeople = Self.effectiveThresholdCapMaxPeople
        }
        return clustering
    }

    /// クラスタごとのアンカー（確認済みの顔の正規化済み埋め込み・新しい順に最大 5）。
    /// B3 マルチプロトタイプ: 割り当ては「重心 or アンカーとの最大類似」になる。
    func anchorsByCluster(limitPerCluster: Int = 5) -> [Int: [[Float]]] {
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
    func loadNegatives() -> [FaceClustering.NegativePair] {
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
    func persist(_ clustering: FaceClustering) {
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

}
