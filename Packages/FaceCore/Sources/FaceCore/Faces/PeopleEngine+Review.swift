import PerceptionCore
import Foundation
import MosaicSupport

// MARK: - 人物レビュー（A1/A2/A3・ADR-46/68）
//
// `PeopleEngine` のうち**レビュー**（「同じ人物？」カード・まとめて確認・回答の反映）と、
// その後始末（再クラスタ）をここに分ける。本体（`PeopleEngine.swift`）は一覧・スキャン・
// 命名に専念する。⚠️ 1 ファイル 774 行で 5 つの関心事が同居していた。振る舞いは変えていない。

extension PeopleEngine {


    /// レビューカード（「同じ人物？」「この写真は◯◯さん？」）を生成する。
    /// 判断が割れるケースだけを選ぶアクティブラーニング＝1 回答あたりの精度改善を最大化。
    /// ⚠️ 所要は `people.reviewItems` として計測する。生成はクラスタ数ぶんの fetch ＋ 重心の総当たり
    /// 比較で、しかも顔スキャンと**同じ `@ModelActor`** 上で走るため、スキャン中は書き込みの後ろに
    /// 並んで待たされる。「Finding faces to review…」が長い場合の切り分けに使う。
    public func reviewItems(limit: Int = 30) async -> [FaceReviewItem] {
        await PerfTrace.measureAsync("people.reviewItems") {
            await store.reviewItems(minFaces: minFaces, limit: limit,
                                    excluding: overexposedReviewIDs())
        }
    }

    /// カードを実際に表示したら呼ぶ（スキップ検知）。`reviewShownLimit` 回見せても
    /// 答えられなかったカードは以後出題せず、別の質問（次点候補）に切り替える。
    public func noteReviewShown(itemID: String) {
        var counts = (UserDefaults.standard.dictionary(forKey: Self.reviewShownKey) as? [String: Int]) ?? [:]
        counts[itemID, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: Self.reviewShownKey)
    }

    /// 既定回数以上見せたのに未回答のカード ID（＝もう聞かない）。
    private func overexposedReviewIDs() -> Set<String> {
        let counts = (UserDefaults.standard.dictionary(forKey: Self.reviewShownKey) as? [String: Int]) ?? [:]
        return Set(counts.filter { $0.value >= Self.reviewShownLimit }.keys)
    }

    private static let reviewShownKey = "faceReviewShownCounts"
    private static let reviewShownLimit = 3

    /// 「同じ人物ですか？」への回答（A1）。
    /// はい → 統合（正例として学習）。いいえ → 「別人」記録（負例・以後提案しない）。
    public func answerSamePerson(aClusterID: Int, bClusterID: Int, same: Bool) async {
        if same {
            await store.mergeClusters(from: bClusterID, into: aClusterID)
        } else {
            await store.markNotSamePerson(clusterA: aClusterID, clusterB: bClusterID)
        }
        // レビューは連続回答する画面で、下の人物一覧は隠れている。回答ごとに全件を再発行すると
        // 1 回答につき 1 回フォアグラウンドが固まる（実機 diagnostics-38・ADR-95）ので、
        // 静止してから 1 回だけ反映する。カードの供給元は `reviewItems` で `people` ではない。
        setNeedsPeopleReload()
    }

    // MARK: - 品質スナップショット（ADR-68）

    /// 実機ライブラリの認識品質を測る（正解ラベル無しで測れる代理指標）。
    /// Developer Options の表示と、診断ログへの記録に使う。
    public func qualityReport() async -> FaceQualityReport {
        await store.qualityReport(minFaces: minFaces)
    }

    /// 品質スナップショットを診断ログへ 1 行記録する（実機で Mac 無しに追える）。
    @discardableResult
    public func logQualityReport() async -> FaceQualityReport {
        let report = await qualityReport()
        Diagnostics.mark(report.logLine)
        // 検出ゲートの棄却内訳も併記する（「顔が取りこぼされている」の切り分け用・ADR-68 追補2）。
        // 起動後のスキャン分のみの集計（プロセス内カウンタ）。
        let detect = FaceDetectionStats.snapshot()
        if detect.candidates > 0 { Diagnostics.mark(detect.logLine) }
        return report
    }

    /// 検出ゲートの棄却内訳（Developer Options 表示用）。
    public nonisolated func detectionStats() -> FaceDetectionStats.Snapshot {
        FaceDetectionStats.snapshot()
    }

    // MARK: - 一括レビュー（ADR-68）

    /// 「この人と同じ人をまとめて選ぶ」1 画面ぶんを取得する。
    /// `anchorClusterID` を渡すと、その人物を基準にする（人物一覧から特定の人を畳むとき）。
    public func batchReviewItem(anchorClusterID: Int? = nil,
                                excludingAnchors: Set<Int> = [],
                                excludingCandidates: Set<Int> = [],
                                limit: Int = 24) async -> FaceBatchReviewItem? {
        await store.batchReviewItem(minFaces: minFaces, anchorClusterID: anchorClusterID,
                                    excludingAnchors: excludingAnchors,
                                    excludingCandidates: excludingCandidates,
                                    limit: limit)
    }

    /// 一括レビューの回答。選ばれたクラスタをアンカーへ統合し、外されたものは「別人」として記録する。
    ///
    /// 統合後にアンカーの重心が育つため、同じアンカーで再取得すると**さらに遠い時期の
    /// クラスタが候補に入る**（＝人間の確認を種にした連鎖）。自動連鎖（ADR-56 で不採用）と違い、
    /// 各段でユーザーの確認を挟むので雪崩式の誤統合が起きない。
    /// 戻り値: 統合できなかった件数（別名どうし・同一写真で共起）。UI が結果を伝えるのに使う。
    @discardableResult
    public func answerBatch(anchorClusterID: Int, same: [Int], notSame: [Int]) async -> Int {
        var rejected = 0
        for id in same where id != anchorClusterID {
            // 一括レビューは小さなアバターを一覧から選ぶ＝1 対 1 の確認より確度が低く、件数も多い。
            // 学習には低い重みで入れる（ADR-68 追補6）。
            if await store.mergeClusters(from: id, into: anchorClusterID,
                                         confidence: .batch) != nil { rejected += 1 }
        }
        for id in notSame where id != anchorClusterID {
            await store.markNotSamePerson(clusterA: anchorClusterID, clusterB: id,
                                          confidence: .batch)
        }
        // 誤統合の痕跡（1 枚に同じ人物が 2 回）はその場で自動修復する。
        // ユーザーに毎回選ばせる操作ではない（実フィードバック・ADR-68 追補6）。
        await store.repairSamePhotoViolations()
        await loadPeople()
        return rejected
    }

    /// 「1 枚の写真に同じ人物が 2 回」を修復する（誤統合の痕跡・ADR-68 追補5）。
    /// 最良の 1 顔だけ残し、外した顔は負例として学習させる（再クラスタで再発しない）。
    @discardableResult
    public func repairSamePhotoViolations() async -> Int {
        let n = await store.repairSamePhotoViolations()
        if n > 0 { await loadPeople() }
        return n
    }

    /// 事後監査「この人物、実は 2 人では？」への回答（A3・ADR-69）。
    /// いいえ（別人）→ **クラスタを 2 つに分割**し、負例として学習する。
    /// はい（同じ人）→ 記録して二度と尋ねない（正例としてしきい値校正にも効く）。
    public func answerSplitCluster(clusterID: Int, groupBFaceIDs: [String], same: Bool) async {
        if same {
            await store.confirmSameGroup(clusterID: clusterID, groupBFaceIDs: groupBFaceIDs)
        } else {
            await store.splitCluster(clusterID: clusterID, faceIDs: groupBFaceIDs)
        }
        setNeedsPeopleReload()   // 連続回答をまとめる（ADR-95）
    }

    /// 「この写真は「◯◯」さんですか？」への回答（A2）。
    /// はい → 確認済み（アンカー＋正例）。いいえ → 分離（負例として学習）。
    public func answerIsThisPerson(faceID: String, yes: Bool) async {
        if yes {
            await store.confirmFace(faceID: faceID)
        } else {
            await store.reassignFace(faceID: faceID, toClusterID: nil)
        }
        setNeedsPeopleReload()   // 連続回答をまとめる（ADR-95）
    }

    // MARK: - 制約付き再クラスタリング（B2・ADR-46）

    /// クラスタ割り当て**規則**の版。しきい値以外のゲート規則を変えたら上げる（ADR-68）。
    /// 上げると次の夜間処理で全体が割り当て直される（顔の再スキャンは不要）。
    /// 1: ADR-57/58（マージンゲート＋サイズ適応）/ 2: ADR-68（競合を見る免除）/
    /// 3: ADR-68 追補（校正上限 0.70→0.55・実効しきい値の頭打ち）/
    /// 4: ADR-126（校正で bar が上がっているときはマージンゲートを免除する）
    /// 5: **ADR-126 の撤回**（4 で人物アルバムが崩れた——特に枚数の少ない人物。版を上げて
    ///    全体を割り当て直し、4 で混ざった顔を元の規則で置き直す＝ユーザー操作なしで回復する）
    /// 6: ADR-130（種の作り直しを修正——代表写真をアンカーに含める・確立した人物の規模を
    ///    引き継ぐ・名前は人に付いていく。5 までの再クラスタで乗っ取られた人物を置き直す）
    /// 7: ADR-132（**名前・代表写真・確認がある人物のメンバーは再クラスタで動かさない**。
    ///    外れるのはユーザーの指摘＝負例に一致した顔だけ。機械の都合でアルバムを割らない）
    /// 8: ADR-134（統合＝ユーザーの「同じ人」表明をアンカーとして残す／束ねたクラスタを
    ///    種に含める。7 までは、まとめて確認や束ねの結果が再クラスタで消えることがあった）
    public static let clusterRuleVersion = 8

    /// 修正が増えていたら全体を割り当て直す（夜間スキャン完了後に呼ばれる）。
    /// 命名済み/確認済みクラスタは ID・名前を保持し、確認顔は must-link として固定。
    public func rebuildClustersIfNeeded() async {
        let markerKey = "faceRebuildCorrectionCount"
        let scanMarkerKey = "faceRebuildScannedCount"
        let dateMarkerKey = "faceRebuildLastDate"
        let defaults = UserDefaults.standard
        let current = await store.correctionCount()
        let scanned = await store.scannedCount()
        let lastRebuilt = defaults.integer(forKey: markerKey)
        let lastScanned = defaults.integer(forKey: scanMarkerKey)
        let lastDate = defaults.object(forKey: dateMarkerKey) as? Date
        // 発火条件（ADR-54 で拡張）: 修正が増えた／新規スキャンが 500 写真以上進んだ／
        // 30 日以上再クラスタしていない、のいずれか（順序依存の誤りを定期的に自己修復する）。
        let correctionsGrew = current > lastRebuilt
        let scansGrew = scanned - lastScanned >= 500
        let stale = lastDate.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? (scanned > 0)
        // 既定しきい値の変更（ADR-56 の 0.45→0.60 等）も再クラスタ対象（版上げ不要の調整を反映）。
        let thresholdKey = "faceRebuildBaseThreshold"
        let thresholdChanged = Float(defaults.double(forKey: thresholdKey)) != tuning.clusterThreshold
        // **割り当て規則**の変更も再クラスタ対象（ADR-68）。しきい値は同じでもゲートの規則が
        // 変われば結果は変わるので、規則に版を振って発火させる。版を上げれば既存ユーザーの
        // 分裂したクラスタが次の夜間処理で畳み直される（再スキャンは不要＝埋め込みは再利用）。
        let ruleKey = "faceRebuildRuleVersion"
        let ruleChanged = defaults.integer(forKey: ruleKey) != Self.clusterRuleVersion
        guard correctionsGrew || scansGrew || stale || thresholdChanged || ruleChanged else { return }
        let result = await store.rebuildClusters()
        defaults.set(current, forKey: markerKey)
        defaults.set(scanned, forKey: scanMarkerKey)
        defaults.set(Date(), forKey: dateMarkerKey)
        defaults.set(Double(tuning.clusterThreshold), forKey: thresholdKey)
        defaults.set(Self.clusterRuleVersion, forKey: ruleKey)
        Diagnostics.mark("faces: rebuild done — clusters=\(result.clusters) moved=\(result.moved) "
                         + "(corrections \(lastRebuilt)→\(current), scans \(lastScanned)→\(scanned), stale=\(stale))")
        // 再クラスタ後の品質を診断ログへ残す（分裂がどれだけ畳めたか・不変条件が破れていないかを
        // 実機で追えるようにする・ADR-68）。
        await logQualityReport()
        await loadPeople()
    }

    /// Developer Options 用: 即時再クラスタリング（動作検証）。
    public func debugRebuildClustersNow() async {
        let result = await store.rebuildClusters()
        Diagnostics.mark("faces: manual rebuild — clusters=\(result.clusters) moved=\(result.moved)")
        await loadPeople()
    }
}
