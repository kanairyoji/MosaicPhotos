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

    static func makeContainer(isStoredInMemoryOnly: Bool = false,
                              modelID: String = ModelGeneration.legacyFace) -> ModelContainer {
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
        // ⚠️ **台帳**扱い（ADR-186）: 人物名・束ね・修正はユーザーの学習結果で作り直せない。
        // 壊れても削除せず退避し、アプリの版が変わった最初の起動では開く前に控えを取る。
        // スキーマ変更は optional 列の追加だけ（軽量マイグレーション）。コンテナ名 "FacesV1" は
        // 採番し直さない（採番＝旧ストアの破棄）。モデル更新は別コンテナの影の世代で行う（ADR-186）。
        return resilientModelContainer(name: Self.containerName(for: modelID), schema: schema, policy: .ledger) { Self.log.error($0) }
    }

    /// 世代（顔モデル ID）ごとのコンテナ名（ADR-186）。既存データの世代は名前 "FacesV1" を据え置き、
    /// 新しいモデルは `Faces-<id>`（影の世代）。同じ ID なら同じコンテナ＝アプリ更新で消えない。
    static func containerName(for modelID: String) -> String {
        if modelID == ModelGeneration.legacyFace { return "FacesV1" }
        let safe = modelID.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "Faces-" + String(safe)
    }

    /// 現行世代のコンテナ名（既存データ）。
    static let containerName = containerName(for: ModelGeneration.legacyFace)

    init(isStoredInMemoryOnly: Bool = false, modelID: String = ModelGeneration.legacyFace) {
        self.init(modelContainer: Self.makeContainer(isStoredInMemoryOnly: isStoredInMemoryOnly, modelID: modelID))
    }

    /// 類似度スケール依存の定数一式（ADR-70）。**同梱モデルの宣言で選ばれる**
    /// （PeopleEngine が provider.tuning を apply する）。既定は facenet（後方互換）。
    var tuning: FaceTuning = .facenet

    /// 昼の逐次割り当て（`recordScan`）で**重心へ入れる**品質の線。これ未満は所属だけ（第2パス）。
    ///
    /// ⚠️ **下げない**（ADR-221・実機相当の品質で計測）。下げるとその日のうちの精度は上がるが、
    /// 夜の作り直しでどの線も同じ水準に戻る＝得は一時的。一方、昼に名前付き人物へ誤って入った
    /// 写りの悪い顔は、名前付き人物のメンバーを動かさない決まり（ADR-132）のために**夜になっても
    /// 外れない**＝名前付きアルバムの純度が恒久的に下がる（LFW 0.914 → 0.891）。
    var dayQualityFloor: Float = FaceStore.qualityFloor
    /// 名前付き人物（種）の重心を**作り直すときに使う顔**の品質の線（`FaceSeedBuilder`）。
    ///
    /// 0.20（ADR-221）: 実機の品質では名前付き人物の顔の多くが 0.40 未満になり、重心が少数の顔で
    /// 作られていた。0.20 で名前付き人物の純度が上がる（LFW 0.914 → 0.952・他は不変）。
    /// 0.10 も同じ結果だったので控えめな方を採る。
    var seedQualityFloor: Float = 0.20

    /// 計測用: 2 つの線を差し替える（クラスタリングの器も作り直す）。
    func setQualityFloorsForTesting(day: Float, seed: Float) {
        dayQualityFloor = day
        seedQualityFloor = seed
        clusteringCache = nil
    }

    func apply(tuning: FaceTuning) {
        guard self.tuning != tuning else { return }
        self.tuning = tuning
        clusteringCache = nil
        thresholdCache = nil
        calibrationSamplesCache = nil   // プロファイルが変われば材料も別空間（ADR-70）
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

    /// 共起 notSame の回数。正本は `MergePolicy`（ADR-213）。
    static var coOccurrenceNotSame: Int { MergePolicy.coOccurrenceNotSame }
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
    /// このストアが発行した fetch の回数（規模テスト用・ADR-119）。
    /// ⚠️ `PerfTrace` のカウンタはプロセス全体で共有されるので、並行して走る別のテストの
    /// 読み出しまで数えてしまう（全体実行でだけ 48 回・170 回と数えて落ちた）。ストアごとに数える。
    var fetchCountForTesting = 0
    /// インメモリ（テスト）の店は高水位を UserDefaults に持たない（テストどうしで ID が繋がらないように）。
    var isEphemeral: Bool { modelContainer.configurations.first?.isStoredInMemoryOnly ?? false }
    var ephemeralHighWater = -1
    /// 負例エグゼンプラ（修正ジャーナル由来・ADR-45）のインメモリキャッシュ。
    /// clusteringCache と同じライフサイクルで再利用し、修正追加で無効化する。
    var negativesCache: [FaceClustering.NegativePair]?
    /// 校正済みしきい値のキャッシュ（B1・ADR-46）。修正追加で無効化。
    var thresholdCache: Float?
    /// 家族グループのメンバー集合のキャッシュ（ADR-119/231）。
    ///
    /// ⚠️ 「行を消してよいか」（`isUserClaimed`）と「枚数フロアを免除するか」
    /// （`peopleClusters`）の両方がこれを見るので、**1 顔ごと・1 クラスタごとに呼ばれる**
    /// ——毎回引くと写真の削除 1 回につきクラスタ数ぶんの往復になる。
    /// グループは数個で、変わるのは CRUD のときだけなので持っておく。
    /// 捨てるのは `invalidatePeopleGroupMembersCache()`（グループを書き換える全経路で呼ぶ）。
    var peopleGroupMembersCache: Set<Int>?

    /// 校正の材料（修正ジャーナルから作った (類似度, 重み) の並び）。
    ///
    /// ⚠️ **修正のたびに全件を読み直さない**（ADR-142）。実機では修正が 8,868 件まで育っており、
    /// 1 回答ごとにこの全件 fetch ＋ 校正計算が走っていた（`people.batchReview.load` が毎回 7 秒）。
    /// 追加は 1 行ずつなので、キャッシュへ**足すだけ**にする。
    struct CalibrationSamples: Sendable {
        var positive: [(Float, Double)] = []
        var negative: [(Float, Double)] = []
    }
    var calibrationSamplesCache: CalibrationSamples?

    /// ユーザー修正から校正したしきい値（サンプル不足なら既定 0.45）。
    func calibratedThreshold() -> Float {
        if let cached = thresholdCache { return cached }
        let t0 = PerfTrace.nowNs()
        let samples = calibrationSamples()
        let t = FaceCalibration.calibratedThreshold(positive: samples.positive,
                                                    negative: samples.negative,
                                                    fallback: tuning.clusterThreshold,
                                                    clamp: tuning.calibrationRange)
        thresholdCache = t
        PerfTrace.logSpan("faces.calibrate", ms: PerfTrace.msSince(t0),
                          detail: "pos=\(samples.positive.count) neg=\(samples.negative.count)")
        if t != tuning.clusterThreshold {
            Self.log.info("faces: calibrated threshold \(t) "
                          + "(pos=\(samples.positive.count) neg=\(samples.negative.count))")
        }
        return t
    }

    /// 修正 1 件を校正の材料へ振り分ける（読み出しと記録で同じ規則を使う）。
    static func appendCalibrationSample(kind: String, similarity: Float, weight: Double,
                                        to samples: inout CalibrationSamples) {
        // ⚠️⚠️ **尺度を混ぜない**（ADR-149）。校正しているのは「顔が人物に入る」しきい値で、
        // その尺度は**顔 × 重心**。`merge`/`notSame` は**重心 × 重心**の類似度なので同じ物差しでは
        // ない（実測でも中央値が 0.79 と 0.71 でずれる）。混ぜると人物ペアの分布が顔の基準を
        // 押し上げる。人物ペアの数字は「あなたの回答から見た基準」（ADR-148）で別に見る。
        switch kind {
        case "confirm", "sameGroup": samples.positive.append((similarity, weight))
        case "reassign": samples.negative.append((similarity, weight))
        default: break   // merge / notSame は人物ペアの尺度（ここでは使わない）
        }
    }

    /// 校正の材料を作る（キャッシュがあればそれを使う）。
    func calibrationSamples() -> CalibrationSamples {
        if let cached = calibrationSamplesCache { return cached }
        let rows = (countedFetchOptional(FetchDescriptor<FaceCorrection>())) ?? []
        // 確度で重み付けする（ADR-68 追補6）。列追加前の行は nil ＝ 1.0 として扱う。
        var samples = CalibrationSamples()
        for r in rows {
            // ⚠️ 類似度はモデルの空間に張り付いている（ADR-70 追補）。別モデル世代の行を混ぜると
            // 校正が壊れる（facenet の 0.5-0.7 が AuraFace の校正を上限 0.40 まで押し上げた実障害）。
            guard (r.profile ?? "facenet") == tuning.name else { continue }
            guard let sim = r.similarity else { continue }
            let w = r.confidence ?? 1.0
            FaceStore.appendCalibrationSample(kind: r.kind, similarity: Float(sim), weight: w,
                                              to: &samples)
        }
        calibrationSamplesCache = samples
        return samples
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

    /// テスト用: 代表写真だけを外す（確認顔は残す）。
    func clearCoverForTesting(clusterID: Int) {
        cluster(clusterID)?.coverFaceID = nil
        try? modelContext.save()
    }

    /// テスト用: この人物の行がまだ在るか。
    func clusterExistsForTesting(_ clusterID: Int) -> Bool { cluster(clusterID) != nil }

    /// テスト用: いまこの人物の代表に選ばれる顔。
    func coverFaceIDForTesting(inCluster clusterID: Int) -> String? {
        bestCoverFace(inCluster: clusterID, coverFaceID: nil)?.faceID
    }

    /// テスト用: この顔が属するクラスタ ID。
    /// ⚠️ 再クラスタは**ID を再利用しない**（ADR-187）ので、作り直したあとの人物を
    /// 固定の ID で指してはいけない。既知のメンバーから引く。
    func clusterIDForTesting(faceID: String) -> Int? { face(byID: faceID)?.clusterID }


    /// テスト用: クラスタ ID → 散らばり（ADR-210）。
    func spreadsForTesting() -> [Int: Double?] {
        Dictionary(uniqueKeysWithValues: allClusters().map { ($0.clusterID, $0.spread) })
    }

    /// テスト用: この人物で**実際に重心へ寄与している**顔（記録された事実・ADR-210）。
    func contributingFaceIDsForTesting(inCluster clusterID: Int) -> [String] {
        faces(inCluster: clusterID).filter { $0.contributesToCentroid == true }
            .map(\.faceID).sorted()
    }

    /// テスト用: 写真 → その写真の顔が属するクラスタ ID（同一写真 cannot-link の検査）。
    func clusterIDsByPhotoForTesting() -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for f in (countedFetchOptional(FetchDescriptor<DetectedFace>())) ?? [] {
            out[f.refKey, default: []].append(f.clusterID)
        }
        return out
    }

    /// テスト用: いまの記録に食い違いがあるか（ADR-210）。
    func centroidDriftFindingsForTesting() -> [FaceCentroidAudit.Finding] {
        let all = (countedFetchOptional(FetchDescriptor<DetectedFace>())) ?? []
        var byCluster: [Int: [DetectedFace]] = [:]
        for f in all where f.clusterID >= 0 { byCluster[f.clusterID, default: []].append(f) }
        return centroidDriftFindings(existing: allClusters(), facesByCluster: byCluster)
    }

    /// テスト用: クラスタ ID → 件数（重心の二重計上を検査する）。
    func clusterCountsForTesting() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: allClusters().map { ($0.clusterID, $0.count) })
    }

    /// ユーザーが「この人物」と表明した行か（名前・束ね・代表写真・**家族グループの所属**）。
    /// 機械の都合で消してはいけない。
    ///
    /// ⚠️ `peopleGroupMembers` に**既定値を置かない**（ADR-231/232）。置くと呼び出し側が
    /// 何も考えずに省略でき、「グループに入れた人だけが保護から漏れる」がまた起きる
    /// ——それがこの引数を足した理由そのもの。**渡す集合は必ずループの外で 1 回作る**
    /// （人物ごとに引き直すと 1,316 人＝1,316 往復・ADR-119）。
    /// 集合の作り方は `peopleGroupMemberClusterIDs()`。
    static func isUserClaimed(_ c: PersonCluster, peopleGroupMembers: Set<Int>) -> Bool {
        (c.name?.isEmpty == false) || c.personGroupID != nil || c.coverFaceID != nil
            || peopleGroupMembers.contains(c.clusterID)
    }

    /// 上に**確認顔**（「この顔はこの人」・ADR-46）を加えた判定（ADR-210）。
    ///
    /// ⚠️ 確認顔も ADR-132 の言う「ユーザーの表明」なのに、行の保護対象から漏れていた。
    /// 名前も代表写真も付けず、レビューで「はい」とだけ答えて育てた人物は、
    /// 最後の 1 顔を外した瞬間に**行ごと消える**（残った顔は孤児になる）。
    /// ⚠️ 顔を 1 回引くので、**最後の 1 顔の経路でだけ**呼ぶ（毎回の削除で引かない）。
    /// グループの集合はキャッシュ（`peopleGroupMembersCache`）なので往復しない。
    func isUserClaimed(_ c: PersonCluster) -> Bool {
        if Self.isUserClaimed(c, peopleGroupMembers: peopleGroupMemberClusterIDs()) { return true }
        return anchorCount(clusterID: c.clusterID) > 0
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
        fetchCountForTesting += 1
        return try? modelContext.fetch(descriptor)
    }

    /// 代表顔を選ぶ。⚠️ **同点は faceID で決定的に決める**（ADR-139）。
    /// 代表顔は見た目だけの話ではない——命名・代表選択でアンカー（確認顔）になり、再クラスタで
    /// 動かない錨になる（ADR-130/132）。同点のときに fetch 順で決まると、
    /// **同じデータでも実行ごとに違う顔が錨になり**、結果が揺れる（テストが CI でだけ落ちた）。
    ///
    /// ⚠️⚠️ **見た目の良さだけで選ばない**（ADR-214）。代表顔は錨になるので、混ざり込んだ
    /// 別人の「よく写った顔」が代表になると、その別人がこの人物の同一性そのものになる
    /// （ADR-130 で実際に起きた「私のアルバムが丸ごと娘になった」の増幅経路）。
    /// 重心から遠い顔＝この人物らしくない顔は、どれだけ綺麗でも候補から外す。
    /// ⚠️ 全員が遠いときは**絞らない**（絞って 0 人になると代表が消え、人物一覧から落ちる）。
    ///
    /// - Parameters:
    ///   - centroid: クラスタの重心（正規化済み）。nil なら従来どおり見た目だけで選ぶ。
    ///   - minSimilarity: この類似未満の顔を候補から外す（0 = 外さない）。
    static func bestCoverFace(_ faces: [DetectedFace], centroid: [Float]? = nil,
                              minSimilarity: Float = 0) -> DetectedFace? {
        var pool = faces
        if let centroid, minSimilarity > 0 {
            let near = faces.filter { f in
                guard let v = ClipMath.decodeHalf(f.embedding) else { return false }
                return FaceClustering.dot(FaceClustering.normalized(v), centroid) >= minSimilarity
            }
            if !near.isEmpty { pool = near }
        }
        return pool.max { a, b in
            let sa = coverScore(a), sb = coverScore(b)
            if sa != sb { return sa < sb }
            return a.faceID > b.faceID   // 同点 → faceID の小さい方を採る
        }
    }

    /// 代表選びに要る値だけを写したもの（`@Model` を持ち回さないため・ADR-227）。
    struct CoverRank: Sendable {
        let faceID: String
        let quality: Double
        let hasSmile: Bool?
        let bw: Double

        init(_ f: DetectedFace) {
            faceID = f.faceID
            quality = f.quality
            hasSmile = f.hasSmile
            bw = f.bw
        }
    }

    /// 値だけで代表を選ぶ（`bestCoverFace` と**同じ規則**）。
    static func bestCoverFaceID(_ candidates: [CoverRank]) -> String? {
        candidates.max { a, b in
            let sa = coverScore(quality: a.quality, hasSmile: a.hasSmile, bw: a.bw)
            let sb = coverScore(quality: b.quality, hasSmile: b.hasSmile, bw: b.bw)
            if sa != sb { return sa < sb }
            return a.faceID > b.faceID   // 同点 → faceID の小さい方を採る
        }?.faceID
    }

    static func coverScore(quality: Double, hasSmile: Bool?, bw: Double) -> Double {
        quality + (hasSmile == true ? 0.3 : 0) + min(bw, 1.0) * 0.2
    }

    /// **読み取り専用の全顔走査**を、使い捨ての `ModelContext` でページ分けして行う（ADR-227）。
    ///
    /// ⚠️ 顔は 10 万件 ×（埋め込み 1KB）なので、本体のコンテキストで全件 fetch すると
    /// **そのまま常駐する**（長生きのコンテキストは実体化した行を登録し続ける）。
    /// ⚠️ ここで取った `@Model` を**本体のコンテキストへ渡さない**（値へ写してから使う）。
    /// テスト用: ページ読みで読んだ**行数**（本体のコンテキストに登録していない行）。
    var pagedFaceRowsForTesting = 0

    func forEachFacePage(_ body: ([DetectedFace]) -> Void) {
        var cursor: String?
        while true {
            let ctx = ModelContext(modelContainer)
            var descriptor: FetchDescriptor<DetectedFace>
            if let cursor {
                descriptor = FetchDescriptor<DetectedFace>(
                    predicate: #Predicate { $0.faceID > cursor },
                    sortBy: [SortDescriptor(\.faceID)])
            } else {
                descriptor = FetchDescriptor<DetectedFace>(sortBy: [SortDescriptor(\.faceID)])
            }
            descriptor.fetchLimit = Self.readPageSize
            guard let page = try? ctx.fetch(descriptor), !page.isEmpty else { return }
            pagedFaceRowsForTesting += page.count
            body(page)
            cursor = page.last?.faceID
            if page.count < Self.readPageSize { return }
        }
    }

    /// 読み取りページの大きさ（実体化した行をページごとに手放す）。
    static let readPageSize = 5_000

    static func coverScore(_ f: DetectedFace) -> Double {
        coverScore(quality: f.quality, hasSmile: f.hasSmile, bw: f.bw)
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
        // この人物らしくない顔は候補から外す（ADR-214）。重心は既に読んである行から取る。
        let centroid = cluster(cid).flatMap { ClipMath.decodeHalf($0.sum) }
            .map { FaceClustering.normalized($0) }
        return Self.bestCoverFace((countedFetchOptional(d)) ?? [], centroid: centroid,
                                  minSimilarity: calibratedThreshold())
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

    /// 候補のうち**まだスキャンしていない**枚数（画面の「残り」表示用）。
    /// ⚠️ `scannedCount()`（記録の総数）を分子にすると、削除済み写真の記録が分子に残り、
    /// 分母（ライブラリ総数）にはスクリーンショット等の候補外が混ざって、**存在しない残作業**が
    /// 表示される（実機: 実際は残 27 枚なのに「残り 1 万枚」）。集合の差で数える。
    func pendingCount(candidateRefKeys: [String]) -> Int {
        let done = scannedRefKeys()
        return candidateRefKeys.reduce(0) { $0 + (done.contains($1) ? 0 : 1) }
    }

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
                // ⚠️ **`place` を使う**（ADR-210）。クラスタ ID だけでは「重心に足したか」が
                // 分からず、重心が凍結されたクラスタ（ADR-210）へ所属だけ付いた場合に
                // 「足した」と誤記録してしまう。事実は足した当人にしか書けない。
                let placement = clustering.place(faceID: faceID, embedding: vec,
                                                 quality: face.quality, negatives: negatives,
                                                 excludedClusterIDs: usedClusters)
                var cid = placement.clusterID
                var contributes = placement.contributed
                var source: FaceLinkSource? = cid >= 0
                    ? (contributes ? .face : .secondPass) : nil
                // 第2パス（ADR-66・recall 回復）: フロア未満で未割当なら、重心を汚さず最寄り人物へ
                // membership だけ割り当てる（クラスタ形成前なら未割当のまま＝夜間 rebuild が拾う）。
                if cid < 0 && face.quality < dayQualityFloor {
                    cid = clustering.assignMembershipOnly(faceID: faceID, embedding: vec,
                                                          excludedClusterIDs: usedClusters)
                    contributes = false
                    source = cid >= 0 ? .secondPass : nil
                }
                if cid >= 0 { usedClusters.insert(cid) }
                modelContext.insert(DetectedFace(
                    faceID: faceID, refKey: refKey,
                    bx: face.boundingBox.origin.x, by: face.boundingBox.origin.y,
                    bw: face.boundingBox.size.width, bh: face.boundingBox.size.height,
                    embedding: face.embedding, quality: Double(face.quality), clusterID: cid,
                    hasSmile: face.hasSmile, captureDate: face.captureDate,
                    contributesToCentroid: contributes, linkSource: source?.rawValue))
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
        let threshold = calibratedThreshold()
        for r in allClusters() {
            guard let sum = ClipMath.decodeHalf(r.sum) else { continue }
            seed.append(FaceClustering.Cluster(
                id: r.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: r.count, faceIDs: r.coverFaceID.map { [$0] } ?? [],
                prototypes: anchors[r.clusterID] ?? []))
        }
        // ノブの設定は `FaceClusteringSetup`（純・テスト対象）に一元化した（ADR-198）——
        // 以前は再クラスタ（`FaceStore+Rebuild`）にも**同じ 10 行がコピー**されていた。
        return FaceClusteringSetup.make(
            threshold: threshold, qualityFloor: dayQualityFloor, tuning: tuning,
            seeds: seed, minimumNextID: clusterIDHighWater() + 1,
            anchoredClusterIDs: Set(anchors.keys))
    }

    /// クラスタごとのアンカー（確認済みの顔の正規化済み埋め込み・新しい順に最大 5）。
    /// B3 マルチプロトタイプ: 割り当ては「重心 or アンカーとの最大類似」になる。
    /// この人物のアンカー（確認顔）の数。0 なら同一性の後ろ盾が無い＝再クラスタで乗っ取られ得る。
    func anchorCount(clusterID: Int) -> Int {
        let rows = countedFetchOptional(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { $0.clusterID == clusterID && $0.confirmedAt != nil })) ?? []
        return rows.count
    }

    /// ⚠️ 既定は **1**（ADR-151）。見本を増やすほど純度が落ちる（FG-NET 実測）。
    func anchorsByCluster(limitPerCluster: Int = 1) -> [Int: [[Float]]] {
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
            // 同一写真の重なりは**写真の事実**で、埋め込みの負例にはしない（ADR-152）。
            guard r.kind != "samePhotoBlock" else { continue }
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
    /// **クラスタ ID は二度と再利用しない**（ADR-187）。
    ///
    /// ⚠️ 以前は「既存クラスタの最大 ID + 1」から採番していた。最大 ID の人物が消える
    /// （写真の削除で顔が無くなる・付け替えで最後の顔が抜ける・掃除）と、**次に生まれた別人が
    /// 同じ ID を受け取る**。ID を持って参照している側（ピープルグループのメンバー・共有セットの
    /// 作成元・開いたままの人物アルバム）は、そのまま**別人を指す**——実フィードバック
    /// 「気がついたらアルバムの中身がごっそり別人になっていた」。
    /// 消えた ID も含めた高水位を UserDefaults に持ち、そこから先しか使わない。
    private var clusterIDHighWaterKey: String { "faces.clusterIDHighWater.\(Self.containerName)" }

    func clusterIDHighWater() -> Int {
        let stored = isEphemeral ? ephemeralHighWater : UserDefaults.standard.integer(forKey: clusterIDHighWaterKey)
        let current = allClusters().map(\.clusterID).max() ?? -1
        return max(stored, current)
    }

    func noteClusterIDs(upTo id: Int) {
        if isEphemeral {
            ephemeralHighWater = max(ephemeralHighWater, id)
        } else if id > UserDefaults.standard.integer(forKey: clusterIDHighWaterKey) {
            UserDefaults.standard.set(id, forKey: clusterIDHighWaterKey)
        }
    }

    func persist(_ clustering: FaceClustering) {
        // ⚠️ クラスタごとに引かない（ADR-119）。既存行は **1 回**取って辞書にする。
        // ここは再クラスタの書き戻しで、クラスタ数ぶんの往復がそのまま
        // `@ModelActor` の占有時間になる（占有中はピープル画面・写真の人物名が待たされる）。
        var existingByID: [Int: PersonCluster] = [:]
        for row in allClusters() { existingByID[row.clusterID] = row }
        noteClusterIDs(upTo: clustering.clusters.map(\.id).max() ?? -1)
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
