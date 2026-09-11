import Foundation
import Testing
@testable import DropboxCore

/// diagnostics-81 の回帰: **自分のアップロードで longpoll が回り続けない**こと。
///
/// バックアップ・共有のコピーは自分が監視しているルートへ落ちるため、`changes=true` が
/// 鳴り続ける。以前はその側にだけ待ちが無く、10 分で 202 周（ログ行の 47%）していた。
@Suite("差分同期のポーリング間隔")
struct SyncPollPacingTests {

    @Test("実変化があれば最小待ち（追従の速さは変えない）")
    func realChangeKeepsItSnappy() {
        #expect(SyncPollPacing.delayNs(emptyStreak: 0) == SyncPollPacing.minDelayNs)
    }

    @Test("空振りが続くほど待ちが延びる（指数・上限つき）")
    func backsOffWhileEmpty() {
        let d1 = SyncPollPacing.delayNs(emptyStreak: 1)
        let d2 = SyncPollPacing.delayNs(emptyStreak: 2)
        let d3 = SyncPollPacing.delayNs(emptyStreak: 3)
        #expect(d1 == SyncPollPacing.minDelayNs)
        #expect(d2 == d1 * 2)
        #expect(d3 == d1 * 4)
        #expect(SyncPollPacing.delayNs(emptyStreak: 50) == SyncPollPacing.maxDelayNs)
        // 何周しても上限を超えない（オーバーフローしない）。
        #expect(SyncPollPacing.delayNs(emptyStreak: 10_000) == SyncPollPacing.maxDelayNs)
    }

    @Test("1 分間の空振りで投げる回数は、以前の 1/10 以下になる")
    func pollsPerMinuteDropSharply() {
        // 以前: 1 周 ≈ 0.7 秒（実測 202 周 / 10 分）→ 1 分あたり約 85 周。
        var elapsedNs: UInt64 = 0
        var polls = 0
        var streak = 0
        let oneMinute: UInt64 = 60_000_000_000
        while elapsedNs < oneMinute {
            streak += 1
            polls += 1
            elapsedNs += 700_000_000 + SyncPollPacing.delayNs(emptyStreak: streak)   // 往復 + 待ち
        }
        #expect(polls <= 8, "空振りでも \(polls) 周/分 回っている（以前は約 85 周）")
    }
}
