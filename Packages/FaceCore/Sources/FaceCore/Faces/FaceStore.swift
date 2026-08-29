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
    /// ⚠️ **専用のシリアルキューで走らせる**（`ModelStoreExecutor` に理由を詳述）。
    /// SwiftData の既定 executor はジョブを**呼び出し元のスレッド**で実行するため、これが無いと
    /// MainActor からの `await store.…` が**メインスレッドで**走る（実測の前面ハングの真因）。
    private nonisolated let executorQueue = ModelStoreExecutor.serialQueue(label: "com.mosaicphotos.store.faces")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    /// テスト用: このストアのジョブがメインスレッドで走っていないかを確かめる
    /// （`unownedExecutor` の回帰検証。`ModelActorExecutorTests` から呼ぶ）。
    func runsOnMainThreadForTesting() -> Bool { Thread.isMainThread }

    static let log = LogChannel(subsystem: "com.mosaicphotos.AutoAlbum", label: "Faces")

    static func makeContainer(isStoredInMemoryOnly: Bool = false) -> ModelContainer {
        // FaceCorrection は追加テーブル（ADR-45）＝加算的マイグレーション（既存の顔データは保持）。
        let schema = Schema([DetectedFace.self, PersonCluster.self, ScannedPhoto.self,
                             FaceCorrection.self, PeopleGroupRecord.self])
        if isStoredInMemoryOnly {
            // ⚠️ **名前を必ず変える**。同名（既定名）のインメモリ構成は、コンテナを作り直しても
            // プロセス内で**同じストアを共有**する——テストが並列に走ると別スイートの顔が
            // 流れ込み、しきい値ぎりぎりの検証が実行のたびに違う結果になる（実際に、単体では
            // 通るのに一括実行では別のテストが落ちる、という形で表に出た）。
            let memory = ModelConfiguration(UUID().uuidString, schema: schema,
                                            isStoredInMemoryOnly: true)
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

    /// この顔が重心（sum/count）に寄与しているか。
    /// 列が無い旧行（nil）は品質フロアで推定する——フロア未満は membership だけだった。
    static func contributesToCentroid(_ face: DetectedFace) -> Bool {
        face.contributesToCentroid ?? (Float(face.quality) >= qualityFloor)
    }

    /// スケール非依存の構造定数（プロファイル共通）。
    ///
    /// **マージンゲートの免除（ADR-126）**: 校正でしきい値が既定より**上がっているときだけ**効かせる。
    /// ⚠️ ADR-68 では「(a) ゲート免除は不採用」としたが、その計測は facenet の既定値（0.50）・
    /// 全体集合のみだった。実フィードバック（名前を付けた数名が何十個にも割れる）を受けて
    /// **混在シナリオ**（重い数人＋長い尾）で測り直したところ、判断が変わった:
    /// - 実機の校正値 0.40 では LFW 混在の**上位5人の分裂 2.4 → 1.6（最悪 7 → 3）**、
    ///   純度 0.927 → 0.926（−0.001）・F1 0.932 で**同値**＝ほぼ無料で分裂だけ減る。
    /// - 既定値 0.35 では FG-NET 混在が F1 0.790 → 0.759 と**悪化**する。
    /// 効くのは「校正が bar を上げた結果、同じ人の別クラスタどうしが恒常的に紛らわしくなった」
    /// 状態のときだけ——だから**上がっているときだけ**免除する（`makeClustering`）。
    ///
    /// ⚠️⚠️ **撤回した（false）**。実機で採用したところ、再クラスタ後に人物アルバムが崩れた
    /// （実フィードバック: 「枚数の少ない人物のアルバムが決定的におかしい。多い人物でも数枚おかしい」）。
    /// データセット計測では「ほぼ無料」（LFW 混在で純度 −0.001）だったのに、実ライブラリでは害が出た。
    /// 理由は分布の違い: 手持ちのデータセットには**「1 人 1,000 枚の主役 ＋ 数枚ずつの他人が数百人」**が
    /// 無い。ゲートを免除すると、紛らわしい顔が「1 位のクラスタ」へ入る——**小さいクラスタほど
    /// 重心が不安定で 1 位になりやすく、他人を吸い込む**。純度の平均は動かなくても、
    /// 小さいアルバムは 1〜2 枚の混入で「決定的におかしい」になる（平均は個々の体験を代表しない）。
    /// 教訓は ADR-126 と face-accuracy.md に残す。値を戻すときは**小さいクラスタを除外する条件**とセットで。
    static let rivalAwareMarginGateWhenCalibratedUp = false
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
    /// 直前の判定を取り消すための控え（ADR-136）。**アプリの実行中だけ**保持する
    /// ——目的は「たった今の 1 手を戻す」で、起動を跨いだ取り消しは戻す先が変わっていて危ない。
    var undoStack: [FaceUndoRecord] = []

    var clusteringCache: FaceClustering?
    /// 負例エグゼンプラ（修正ジャーナル由来・ADR-45）のインメモリキャッシュ。
    /// clusteringCache と同じライフサイクルで再利用し、修正追加で無効化する。
    var negativesCache: [FaceClustering.NegativePair]?
    /// 校正済みしきい値のキャッシュ（B1・ADR-46）。修正追加で無効化。
    var thresholdCache: Float?

    /// ユーザー修正から校正したしきい値（サンプル不足なら既定 0.45）。
    func calibratedThreshold() -> Float {
        if let cached = thresholdCache { return cached }
        let rows = (countedFetchOptional(FetchDescriptor<FaceCorrection>())) ?? []
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
        return countedFetchOptional(d)?.first
    }

    /// テスト用: クラスタ内の faceID 一覧。
    func facesForTesting(inCluster clusterID: Int) -> [String] {
        faces(inCluster: clusterID).map(\.faceID)
    }

    /// テスト用: クラスタ ID → 件数（重心の二重計上を検査する）。
    func clusterCountsForTesting() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: allClusters().map { ($0.clusterID, $0.count) })
    }

    func allClusters() -> [PersonCluster] {
        (countedFetchOptional(FetchDescriptor<PersonCluster>())) ?? []
    }

    /// 代表顔の自動選択スコア: 品質を軸に、笑顔（+0.3）と顔の大きさ（bw・最大+0.2）で加点。
    /// ユーザーが代表を指定済み（coverFaceID）の場合は呼ばれない。
    /// すべての fetch はここを通す（**発行回数を数える**＝規模退行テストの土台・ADR-119）。
    ///
    /// ⚠️ 実機で繰り返した性能バグは、どれも「1 回ぶんに見える呼び出しが、実はライブラリ規模に
    /// 比例していた」形だった（クラスタごとに 1 本引く → 1,316 回、対ごとに全記録を舐める…）。
    /// 回数が数えられれば、**規模を変えても増えないこと**をテストで固定できる。
    /// 時間ではなく回数を見るので CI で揺れない。
    /// 境界の顔を探すときに走査するクラスタ数の上限。
    /// 並びは「命名済み優先 → 大きい順」なので、先頭から見れば質問の価値は保てる。
    /// 上限が無いと、境界顔が出ないライブラリでは全クラスタを 1 件ずつ引くことになる。
    static let boundaryScanLimit = 60

    func countedFetchOptional<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> [T]? {
        PerfTrace.count("faceStore.fetch")
        return try? modelContext.fetch(descriptor)
    }

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
        return countedFetchOptional(d)?.first
    }

    /// レビュー候補の生成に要る列だけを持つ軽量な顔（@Model を持ち回らない）。
    struct FaceDigest: Sendable {
        let faceID: String
        let clusterID: Int
        let refKey: String
        let box: CGRect
        let quality: Double
        let hasSmile: Bool?

        /// 代表顔の score（`FaceStore.coverScore` と同じ式・ここでしか使わない）。
        var coverScore: Double { quality + (hasSmile == true ? 0.3 : 0) + min(box.width, 1.0) * 0.2 }
    }

    /// クラスタに属する顔を**1 回の射影クエリ**でまとめて取り、クラスタごとに束ねて返す。
    ///
    /// ⚠️ 2 つの罠を同時に避ける必要がある。
    /// 1. **クラスタごとに引かない**（実測: 1,316 人で 1 画面あたり 1,316〜2,632 回の fetch。
    ///    人物が増えるほど遅くなる＝機能が育つほど使えなくなる）。
    /// 2. **全カラムを materialize しない**（ADR-88。埋め込み込みで数万件の @Model が立ち上がり、
    ///    1.2〜1.4 秒のフリーズとメモリ跳ね上がりになる）。
    /// 射影（`propertiesToFetch`）で必要な列だけを 1 回で取るのが両立の答え。
    func faceDigestsByCluster() -> [Int: [FaceDigest]] {
        var d = FetchDescriptor<DetectedFace>()
        d.propertiesToFetch = [\.faceID, \.clusterID, \.refKey, \.bx, \.by, \.bw, \.bh,
                               \.quality, \.hasSmile]
        let rows = (countedFetchOptional(d)) ?? []
        var out: [Int: [FaceDigest]] = [:]
        for row in rows where row.clusterID >= 0 {           // 未割り当て（-1）は対象外
            out[row.clusterID, default: []].append(FaceDigest(
                faceID: row.faceID, clusterID: row.clusterID, refKey: row.refKey,
                box: CGRect(x: row.bx, y: row.by, width: row.bw, height: row.bh),
                quality: row.quality, hasSmile: row.hasSmile))
        }
        return out
    }

    /// **指定したクラスタの顔だけ**を射影クエリで取り、クラスタごとに束ねて返す。
    ///
    /// ⚠️ レビューの候補生成は、以前ここで `faceDigestsByCluster()`（**全顔**）を呼んでいた。
    /// 実際に要るのは「基準の人物と、その候補になった数十クラスタ」だけで、
    /// 数枚しかない無名の人物の顔まで毎回読む必要はない（実フィードバック: 候補探しが遅い）。
    /// SQLite の変数上限があるので ID は分割して問い合わせる（分割しても往復は
    /// 「クラスタ数 ÷ chunk」で、ライブラリ全体の顔数には比例しない）。
    func faceDigests(inClusters ids: Set<Int>) -> [Int: [FaceDigest]] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int: [FaceDigest]] = [:]
        for chunk in Self.idChunks(ids) {
            var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { chunk.contains($0.clusterID) })
            d.propertiesToFetch = [\.faceID, \.clusterID, \.refKey, \.bx, \.by, \.bw, \.bh,
                                   \.quality, \.hasSmile]
            for row in (countedFetchOptional(d)) ?? [] where row.clusterID >= 0 {
                out[row.clusterID, default: []].append(FaceDigest(
                    faceID: row.faceID, clusterID: row.clusterID, refKey: row.refKey,
                    box: CGRect(x: row.bx, y: row.by, width: row.bw, height: row.bh),
                    quality: row.quality, hasSmile: row.hasSmile))
            }
        }
        return out
    }

    /// 1 回の `IN` に載せる ID 数（SQLite の変数上限に余裕を持たせる）。
    static let idChunkSize = 400

    /// ID を一定数で切る（切っても往復は「ID 数 ÷ この値」で、ライブラリ規模には比例しない）。
    static func idChunks(_ ids: Set<Int>) -> [[Int]] {
        let list = Array(ids)
        return stride(from: 0, to: list.count, by: idChunkSize).map {
            Array(list[$0..<min($0 + idChunkSize, list.count)])
        }
    }

    /// テスト用: 束ね直しの結果（faceID とクラスタの対応）。
    func faceDigestsForTesting() -> [(faceID: String, clusterID: Int)] {
        faceDigestsByCluster().values.flatMap { $0 }.map { ($0.faceID, $0.clusterID) }
    }

    func faces(inCluster clusterID: Int) -> [DetectedFace] {
        let cid = clusterID
        return (countedFetchOptional(
            FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid }))) ?? []
    }

    /// **全クラスタ**のメンバー写真（refKey）を 1 回の射影クエリで取り、クラスタごとに束ねる。
    ///
    /// ⚠️ クラスタごとに `memberRefKeys(inCluster:)` を呼ぶ形は、人物が増えるほど往復が増える
    /// （ADR-119 の規模退行テストが検出）。全クラスタを走査する処理はこちらを使う。
    func memberRefKeysByCluster() -> [Int: Set<String>] {
        var d = FetchDescriptor<DetectedFace>()
        d.propertiesToFetch = [\.clusterID, \.refKey]
        var out: [Int: Set<String>] = [:]
        for row in countedFetchOptional(d) ?? [] where row.clusterID >= 0 {
            out[row.clusterID, default: []].insert(row.refKey)
        }
        return out
    }

    /// クラスタのメンバー写真（refKey）だけを取る**射影クエリ**（ADR-88）。
    /// 共起判定に必要なのは refKey の集合だけなのに、`faces(inCluster:)` で全カラムを
    /// materialize すると、レビュー候補の生成（全クラスタを走査）で数万件の @Model が
    /// 立ち上がり、実測 1.2〜1.4 秒のフリーズとメモリ跳ね上がりの原因になっていた。
    func memberRefKeys(inCluster clusterID: Int) -> Set<String> {
        let cid = clusterID
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID == cid })
        d.propertiesToFetch = [\.refKey]
        return Set(((countedFetchOptional(d)) ?? []).map(\.refKey))
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
        return Self.bestCoverFace((countedFetchOptional(d)) ?? [])
    }

    func faces(inPhoto refKey: String) -> [DetectedFace] {
        let key = refKey
        return (countedFetchOptional(
            FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.refKey == key }))) ?? []
    }

    // MARK: - スキャン進捗

    /// スキャン済みの refKey 集合（tagger が候補からメモリ差分を取るため一度だけ取得する）。
    func scannedRefKeys() -> Set<String> {
        let markers = (countedFetchOptional(FetchDescriptor<ScannedPhoto>())) ?? []
        return Set(markers.map(\.refKey))
    }

    func scannedCount() -> Int { (try? modelContext.fetchCount(FetchDescriptor<ScannedPhoto>())) ?? 0 }

    /// 全スキャン済み写真の refKey → 顔数（実測）。AI アルバムの「人が写っていない」判定に使う。
    func scannedFaceCounts() -> [String: Int] {
        let markers = (countedFetchOptional(FetchDescriptor<ScannedPhoto>())) ?? []
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
        return (countedFetchOptional(d))?.first?.faceCount
    }

    // MARK: - 記録＋逐次クラスタリング

    /// 複数写真分の検出結果をまとめて記録する（T3: save をバッチ 1 回に）。
    /// 従来は写真ごとに save しており、13k 枚のスキャンで 13k 回の SQLite save が発生していた。
    /// - Returns: **永続化できたか**。取り込み側は成功したときだけ「取り込み済み」を記録する。
    @discardableResult
    func recordScans(_ batch: [(refKey: String, faces: [DetectedFaceSignal])]) -> Bool {
        for entry in batch {
            recordScan(refKey: entry.refKey, faces: entry.faces, deferSave: true)
        }
        do {
            try modelContext.save()
            return true
        } catch {
            Self.log.error("recordScans: save failed — \(error)")
            modelContext.rollback()
            clusteringCache = nil   // 途中まで進んだ状態を捨てる
            return false
        }
    }

    /// 1 写真分の検出結果を記録する（顔行＋マーカー）。各顔を既存クラスタへ逐次割り当てる。
    func recordScan(refKey: String, faces: [DetectedFaceSignal], deferSave: Bool = false) {
        // すでに記録済みなら二重記録しない。
        let key = refKey
        var marker = FetchDescriptor<ScannedPhoto>(predicate: #Predicate { $0.refKey == key })
        marker.fetchLimit = 1
        if (countedFetchOptional(marker)?.first) != nil { return }

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
                // 重心に寄与したか（＝本割り当てで入ったか）を**行に残す**。付け替え時に
                // 「引いてよい顔か」を後から確実に判定するため（レビュー指摘）。
                var contributes = cid >= 0
                // 第2パス（ADR-66・recall 回復）: フロア未満で未割当なら、重心を汚さず最寄り人物へ
                // membership だけ割り当てる（クラスタ形成前なら未割当のまま＝夜間 rebuild が拾う）。
                if cid < 0 && face.quality < Self.qualityFloor {
                    cid = clustering.assignMembershipOnly(faceID: faceID, embedding: vec,
                                                          excludedClusterIDs: usedClusters)
                    contributes = false
                }
                if cid >= 0 { usedClusters.insert(cid) }
                modelContext.insert(DetectedFace(
                    faceID: faceID, refKey: refKey,
                    bx: face.boundingBox.origin.x, by: face.boundingBox.origin.y,
                    bw: face.boundingBox.size.width, bh: face.boundingBox.size.height,
                    embedding: face.embedding, quality: Double(face.quality), clusterID: cid,
                    hasSmile: face.hasSmile, captureDate: face.captureDate,
                    contributesToCentroid: contributes))
            }
            persist(clustering)
            clusteringCache = clustering   // 次の写真はここから逐次継続（全復元しない）
        }
        if !deferSave { try? modelContext.save() }
    }

    /// テスト用: 校正済みしきい値を差し替える（校正サンプルを作らずに「bar が上がった状態」を作る）。
    func setThresholdForTesting(_ value: Float) {
        thresholdCache = value
        clusteringCache = nil
    }

    /// テスト用: 重心を差し替える（別人へ引きずられた状態＝ドリフトを作る）。
    func setClusterSumForTesting(clusterID: Int, vector: [Float]) {
        guard let c = cluster(clusterID) else { return }
        c.sum = ClipMath.encodeHalf(vector)
        clusteringCache = nil
        try? modelContext.save()
    }

    /// テスト用: この人物のアンカーを外す（ADR-130 以前に作られた「名前だけの人物」を再現する）。
    func clearAnchorsForTesting(clusterID: Int) {
        for f in faces(inCluster: clusterID) { f.confirmedAt = nil }
        cluster(clusterID)?.coverFaceID = nil
        clusteringCache = nil
        try? modelContext.save()
    }

    /// テスト用: クラスタ ID → 名前。
    func namesByClusterForTesting() -> [Int: String] {
        var out: [Int: String] = [:]
        for c in allClusters() {
            guard let n = c.name, !n.isEmpty else { continue }
            out[c.clusterID] = n
        }
        return out
    }

    /// テスト用: 現在の設定で組んだクラスタリング（免除の配線を検証する）。
    func loadClusteringForTesting() -> FaceClustering {
        clusteringCache = nil
        return loadClustering()
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
        // マージンゲートの免除（ADR-126・校正で bar が上がっているときだけ）
        clustering.rivalAwareMarginGate = Self.rivalAwareMarginGateWhenCalibratedUp
            && clustering.threshold > tuning.clusterThreshold
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
    /// この人物のアンカー（確認顔）の数。0 なら同一性の後ろ盾が無い＝再クラスタで乗っ取られ得る。
    func anchorCount(clusterID: Int) -> Int {
        let rows = countedFetchOptional(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { $0.clusterID == clusterID && $0.confirmedAt != nil })) ?? []
        return rows.count
    }

    func anchorsByCluster(limitPerCluster: Int = 5) -> [Int: [[Float]]] {
        let confirmed = (countedFetchOptional(FetchDescriptor<DetectedFace>(
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
        let rows = (countedFetchOptional(d)) ?? []
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
        // ⚠️ クラスタごとに引かない（ADR-119）。既存行は **1 回**取って辞書にする。
        // ここは再クラスタの書き戻しで、クラスタ数ぶんの往復がそのまま
        // `@ModelActor` の占有時間になる（占有中はピープル画面・写真の人物名が待たされる）。
        var existingByID: [Int: PersonCluster] = [:]
        for row in allClusters() { existingByID[row.clusterID] = row }
        for c in clustering.clusters {
            if let existing = existingByID[c.id] {
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
