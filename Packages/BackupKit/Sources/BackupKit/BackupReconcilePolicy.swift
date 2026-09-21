import Foundation

/// 「Dropbox と照合する頃合いか」を決める純ロジック（ADR-166）。
///
/// ⚠️ `BackupEngine` に直書きすると、判定を確かめるのに Dropbox 接続と実機の時計が要る
/// ＝実質テストできない。間隔の判定はここに出す。
public enum BackupReconcilePolicy {

    /// - Parameters:
    ///   - lastRun: 前回の照合時刻（**記録が無ければ実行する**＝初回に基準時刻を作る）。
    ///   - interval: 最短間隔（既定 7 日）。
    public static func isDue(lastRun: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastRun else { return true }
        // ⚠️ 端末の時計が巻き戻る（手動設定・タイムゾーン）ことはある。
        // 差が負なら「間隔が空いた」と扱う——巻き戻りで**永久に照合されない**方が困る。
        let elapsed = now.timeIntervalSince(lastRun)
        return elapsed < 0 || elapsed >= interval
    }

    /// 照合に**失敗した回**に刻む時刻（ADR-206）。
    ///
    /// ⚠️ 開始前に `now` を刻むのは、通信断の端末が窓のたびに数万件の一覧を投げないため。
    /// ただしそのままだと**失敗しても次は 7 日後**で、窓が途中で切れた回のぶんだけ
    /// オフロードの緊急停止が丸 1 週間遅れる。失敗の回だけ間隔を縮めて、
    /// 「毎晩叩く」と「1 週間待つ」の間を取る。
    /// - Returns: 次の期限が `now + retryAfter` になるような刻印。
    public static func stampAfterFailure(now: Date, interval: TimeInterval,
                                         retryAfter: TimeInterval) -> Date {
        // 巻き戻し過ぎない（retryAfter > interval なら now のまま＝通常の間隔）。
        now.addingTimeInterval(-max(0, interval - retryAfter))
    }
}
