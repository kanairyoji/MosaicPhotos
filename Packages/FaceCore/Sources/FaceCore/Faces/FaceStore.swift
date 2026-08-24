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
        let schema = Schema([DetectedFace.self, PersonCluster.self, ScannedPhoto.self,
                             FaceCorrection.self, PeopleGroupRecord.self])
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        }
        return resilientModelContainer(name: "FacesV1", schema: schema) { Self.log.error($0) }
    }

    init(isStoredInMemoryOnly: Bool = false) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly))
    }

    /// 類似度スケール依存の定数一式（ADR-70）。**同梱モデルの宣言で選ばれる**
    /// （PeopleEngine が provider.tuning を apply する）。既定は facenet（後方互換）。
    var tuning: FaceTuning = .facenet

    func apply(tuning: FaceTuning) {
        guard self.tuning != tuning else { return }
        self.tuning = tuning
        clusteringCache = nil
        thresholdCache = nil
    }

    /// この品質未満の顔はクラスタへ割り当てない（ADR-45/53）。Vision の
    /// faceCaptureQuality スケール＝**顔モデル非依存**なのでプロファイル外。
    static let qualityFloor: Float = 0.40

    /// スケール非依存の構造定数（プロファイル共通）。
    static let rivalAwareSizeMargin = true
    static let rivalAwareSizeMarginMaxPeople = 10
    static let capEffectiveThresholdWhenFewPeople = true
    static let effectiveThresholdCapMaxPeople = 10

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
        // 確度で重み付けする（ADR-68 追補6）。列追加前の行は nil ＝ 1.0 として扱う。
        var positive: [(Float, Double)] = []
        var negative: [(Float, Double)] = []
        for r in rows {
            // ⚠️ 類似度はモデルの空間に張り付いている（ADR-70 追補）。別モデル世代の行を混ぜると
            // 校正が壊れる（facenet の 0.5-0.7 が AuraFace の校正を上限 0.40 まで押し上げた実障害）。
            guard (r.profile ?? "facenet") == tuning.name else { continue }
            guard let sim = r.similarity else { continue }
            let w = r.confidence ?? 1.0
            switch r.kind {
            case "merge", "confirm", "sameGroup":  positive.append((Float(sim), w))
            case "reassign", "notSame":  negative.append((Float(sim), w))
            default: break
            }
        }
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative,
                                                    fallback: tuning.clusterThreshold,
                                                    clamp: tuning.calibrationRange)
        thresholdCache = t
        if t != tuning.clusterThreshold {
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

    /// テスト用: クラスタ ID → 件数（重心の二重計上を検査する）。
    func clusterCountsForTesting() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: allClusters().map { ($0.clusterID, $0.count) })
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

    /// クラスタのメンバー写真（refKey）だけを取る**射影クエリ**（ADR-88）。
    /// 共起判定に必要なのは refKey の集合だけなのに、`faces(inCluster:)` で全カラムを
    /// materialize すると、レビュー候補の生成（全クラスタを走査）で数万件の @Model が
    /// 立ち上がり、実測 1.2〜1.4 秒のフリーズとメモリ跳ね上がりの原因になっていた。
    func memberRefKeys(inCluster clusterID: Int) -> Set<String> {
        let cid = clusterID
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid })
        d.propertiesToFetch = [\.refKey]
        return Set(((try? modelContext.fetch(d)) ?? []).map(\.refKey))
    }

    /// クラスタの代表顔を取る（ADR-88）。`coverFaceID` があればその 1 件だけを引き、
    /// 無ければ品質上位の少数から選ぶ。全メンバーの materialize を避けるための軽量版。
    func bestCoverFace(inCluster clusterID: Int, coverFaceID: String?) -> DetectedFace? {
        if let coverFaceID, let f = face(byID: coverFaceID) { return f }
        let cid = clusterID
        var d = FetchDescriptor<DetectedFace>(
            predicate: #Predicate { $0.clusterID == cid },
            sortBy: [SortDescriptor(\.quality, order: .reverse)])
        d.fetchLimit = 16   // 品質上位だけ見れば代表は決まる（笑顔・大きさの微調整のみ）
        return Self.bestCoverFace((try? modelContext.fetch(d)) ?? [])
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
        clustering.assignMargin = tuning.assignMargin   // マージンゲート（ADR-57）
        clustering.sizeAdaptiveMarginMax = tuning.sizeAdaptiveMarginMax   // サイズ適応（ADR-58）
        clustering.negativeSameThreshold = tuning.negativeSameThreshold
        // サイズ適応マージンの免除（ADR-68・少人数ライブラリ限定）
        clustering.rivalAwareSizeMargin = Self.rivalAwareSizeMargin
        clustering.rivalAwareSizeMarginMaxPeople = Self.rivalAwareSizeMarginMaxPeople
        clustering.rivalAlikeMargin = tuning.rivalAlikeMargin
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
            // 別モデル世代の埋め込みは別空間＝照合不能（ADR-70 追補）。
            guard (r.profile ?? "facenet") == tuning.name else { continue }
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
