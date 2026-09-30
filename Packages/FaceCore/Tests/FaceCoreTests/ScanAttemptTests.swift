import Foundation
import Testing
@testable import FaceCore

/// **何度やっても画像が取れない写真を、いつ諦めるか**（ADR-243・実機ログ diagnostics-101）。
///
/// ⚠️⚠️ **なぜ既存テストで捕まらなかったか**（ここが本題）。
/// ADR-92 の不変条件「解析できなかった写真を走査済みとして記録しない」は
/// `FaceTaggerRecordingTests` が守っていて、`StarvedProvider`（何も解析できない）まで用意してある。
/// それでも 6 時間ぶん空回りする不具合を見逃した——理由は**テストが scan を 1 回しか回さない**から。
/// 「記録しない」は 1 回の実行で確かめられるが、
/// 「**次の窓でまた来る／来ない**」は 2 回以上回さないと見えない。
/// 無限ループは*繰り返しの性質*なので、1 回のテストからは原理的に見えなかった。
/// → このスイートは**同じ写真を何度も回す**ことだけを見る。
///
/// ⚠️ 実時間を待たない（ADR-241）。`now` を引数で渡して規則を固定する。
@Suite("取れない写真を諦める規則", .serialized)
struct ScanAttemptTests {

    // MARK: - 純ロジック

    @Test("間隔が空いていれば数え直す。空いていなければ数えない")
    func cooldownRule() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        #expect(!ScanAttemptPolicy.countsAgain(lastFailureAt: t0, now: t0, cooldown: 3600))
        #expect(!ScanAttemptPolicy.countsAgain(lastFailureAt: t0,
                                               now: t0.addingTimeInterval(3599), cooldown: 3600))
        // ⚠️ ちょうど境界は「数える」。切り捨てると時計の粒度で永久に数えられない写真が出る。
        #expect(ScanAttemptPolicy.countsAgain(lastFailureAt: t0,
                                              now: t0.addingTimeInterval(3600), cooldown: 3600))
    }

    @Test("上限に達したかは failures >= limit")
    func exhaustedRule() {
        #expect(!ScanAttemptPolicy.isExhausted(failures: 4, limit: 5))
        #expect(ScanAttemptPolicy.isExhausted(failures: 5, limit: 5))
        #expect(ScanAttemptPolicy.isExhausted(failures: 9, limit: 5))
    }

    // MARK: - 台帳

    @Test("別の窓で上限回数ぶん失敗したら、候補から外れる")
    func dropsAfterFailingInSeparateWindows() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)

        // ⚠️ 上限に**達するまでは外さない**（ここが「一時的な失敗を捨てない」側の保証）。
        for round in 1..<FaceStore.maxScanLoadFailures {
            let exhausted = await store.recordScanLoadFailures(["C-x"], now: now)
            #expect(exhausted.isEmpty, "\(round) 回目で外している（一時的な失敗を諦めている）")
            #expect(await store.unreadableRefKeys().isEmpty,
                    "\(round) 回目で候補から外れている")
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }

        let exhausted = await store.recordScanLoadFailures(["C-x"], now: now)

        #expect(exhausted == ["C-x"], "上限に達したのに記録へ出していない")
        #expect(await store.unreadableRefKeys() == ["C-x"], "上限に達しても候補に残っている")
        #expect(await store.scanLoadFailureCounts() == (tracked: 1, exhausted: 1))
    }

    /// ⚠️⚠️ **ここが本丸**。同じ窓で何千枚が巻き込まれる（閲覧中の譲り・回線断）形では、
    /// 1 枚あたり 1 回しか数えないこと——数えてしまうと、
    /// **閲覧しながら寝た晩に数千枚が永久に落ちる**。
    @Test("同じ窓で何度失敗しても 1 回しか数えない")
    func countsOncePerWindow() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let now = Date(timeIntervalSince1970: 1_000_000)

        for _ in 0..<50 { _ = await store.recordScanLoadFailures(["C-x"], now: now) }

        #expect(await store.unreadableRefKeys().isEmpty, """
            同じ窓の失敗を何度も数えて外してしまった。
            譲り・回線断は 1 つの窓で何千枚を巻き込むので、これをやると全部落ちる。
            """)
        #expect(await store.scanLoadFailureCounts() == (tracked: 1, exhausted: 0))
    }

    @Test("取れたら記録を忘れる（一時的な失敗を溜め込まない）")
    func forgetsOnSuccess() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<3 {
            _ = await store.recordScanLoadFailures(["C-x"], now: now)
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }
        #expect(await store.scanLoadFailureCounts().tracked == 1, "fixture: 記録が無い")

        await store.clearScanLoadFailures(["C-x"])

        #expect(await store.scanLoadFailureCounts() == (tracked: 0, exhausted: 0),
                "取れたのに失敗の記録が残っている（次に少し失敗したら外れてしまう）")
    }

    /// ⚠️ **忘れる経路が無い負のキャッシュは作らない**（ADR-82）。
    /// 記録だけ足して忘れ方が無いと、版を上げて全部やり直すときに外した写真だけ戻ってこない。
    @Test("全再スキャンで記録を忘れる")
    func resetForgetsEverything() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0...FaceStore.maxScanLoadFailures {
            _ = await store.recordScanLoadFailures(["C-x", "L-y"], now: now)
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }
        #expect(await store.unreadableRefKeys().count == 2, "fixture: 外れていない")

        await store.reset()

        #expect(await store.unreadableRefKeys().isEmpty, "再スキャンしても外したままになっている")
    }

    @Test("クラウドだけ測り直したら、クラウドの記録だけ忘れる")
    func cloudResetForgetsOnlyCloud() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var now = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0...FaceStore.maxScanLoadFailures {
            _ = await store.recordScanLoadFailures(["C-x", "L-y"], now: now)
            now = now.addingTimeInterval(FaceStore.scanFailureCooldown)
        }
        #expect(await store.unreadableRefKeys().count == 2, "fixture: 外れていない")

        await store.resetCloudScanLoadFailures()

        #expect(await store.unreadableRefKeys() == ["L-y"],
                "クラウドだけ忘れるはずが、端末内の記録まで消えた（または消えていない）")
    }
}
