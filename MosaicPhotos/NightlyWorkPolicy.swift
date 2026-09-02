import Foundation

/// 夜間ウィンドウで「この窓は何をする窓か」を決める純ロジック（ADR-163/166）。
///
/// ⚠️ 判定を `HeavyWorkScheduler` に直書きすると、**BGTask を起こさないと確かめられない**
/// ＝実質テストできない。窓の使い方は実機で 2 度失敗している（生成と解析の共倒れ・
/// バックアップの飢餓）ので、条件はここに出してテストで固定する。
enum NightlyWorkPolicy {

    // MARK: - アルバム生成を見送るか（ADR-163）

    /// 解析（顔・埋め込み）の残作業があるうちは生成を見送る。ただし**連続見送りの上限**で
    /// 順番を回す——生成も飢えさせない（バックアップの公平性ルール＝ADR-72 と同じ形）。
    enum GenerateDecision: Equatable {
        /// 見送る（値は「これで連続何回目か」＝記録する値）。
        case defer_(streak: Int)
        /// 実行する（値は直前までの連続見送り回数＝ログ用。実行時は 0 に戻す）。
        case run(afterDeferrals: Int)
    }

    static func generateDecision(embedBacklog: Int, faceBacklog: Int,
                                 deferrals: Int, maxDeferrals: Int) -> GenerateDecision {
        let hasBacklog = embedBacklog > 0 || faceBacklog > 0
        guard hasBacklog, deferrals < maxDeferrals else { return .run(afterDeferrals: deferrals) }
        return .defer_(streak: deferrals + 1)
    }

    // MARK: - 週 1 回の照合（ADR-166）

    /// 前回からの経過が `interval` を超えたか。**記録が無ければ実行する**
    /// （初回は必ず 1 回走らせて基準時刻を作る）。
    static func isReconcileDue(lastRun: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }
}
