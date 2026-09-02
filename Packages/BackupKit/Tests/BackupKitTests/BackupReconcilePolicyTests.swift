import Foundation
import Testing
@testable import BackupKit

/// 週 1 回の自動照合（ADR-166）。
///
/// ⚠️ 照合は全件の list_folder なので、**間隔を守れないと毎晩数万件を引く**ことになる。
/// 逆に走らないと、Dropbox 側で消された写真に気づけない（共有の自己修復もコピー元を失う）。
/// 「走りすぎない」「止まらない」の両方をここで固定する。
@Suite("バックアップ照合の間隔")
struct BackupReconcilePolicyTests {

    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("記録が無ければ実行する（初回に基準時刻を作る）")
    func firstRunIsDue() {
        #expect(BackupReconcilePolicy.isDue(lastRun: nil, now: now, interval: week))
    }

    @Test("間隔内は走らない")
    func withinIntervalIsNotDue() {
        let sixDaysAgo = now.addingTimeInterval(-6 * 24 * 60 * 60)
        #expect(BackupReconcilePolicy.isDue(lastRun: sixDaysAgo, now: now, interval: week) == false)
    }

    @Test("間隔ちょうど・超過なら走る")
    func atOrAfterIntervalIsDue() {
        #expect(BackupReconcilePolicy.isDue(lastRun: now.addingTimeInterval(-week),
                                            now: now, interval: week))
        #expect(BackupReconcilePolicy.isDue(lastRun: now.addingTimeInterval(-week * 2),
                                            now: now, interval: week))
    }

    /// ⚠️ 端末の時計は巻き戻る（手動設定・タイムゾーン変更）。負の経過で「まだ」と判断すると
    /// **永久に照合されない**——巻き戻りは走らせる側に倒す。
    @Test("時計が巻き戻っても止まらない")
    func clockSkewDoesNotBlockForever() {
        let future = now.addingTimeInterval(60 * 60 * 24 * 30)   // 未来の記録
        #expect(BackupReconcilePolicy.isDue(lastRun: future, now: now, interval: week))
    }
}
