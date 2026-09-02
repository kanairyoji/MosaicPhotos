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
}
