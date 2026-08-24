import Foundation
import Testing
@testable import MosaicSupport

/// ⚠️ BGTask の完了通知は 1 回だけ。期限切れハンドラと本体の終了処理が
/// **どちらも**通知すると BGTaskScheduler が例外を投げる（レビュー指摘）。
@Suite("CompletionLatch")
@MainActor
struct CompletionLatchTests {

    @Test("最初の 1 回だけ実行される")
    func runsOnlyOnce() {
        let latch = CompletionLatch()
        var calls = 0
        #expect(latch.completeOnce { calls += 1 })
        #expect(!latch.completeOnce { calls += 1 }, "2 回目も通ってしまう（二重通知）")
        #expect(calls == 1)
        #expect(latch.hasCompleted)
    }

    /// 期限切れ → 本体の終了、という実際の順序。
    @Test("期限切れが先に通知したら、本体側は通知しない")
    func expirationWinsOverCompletion() {
        let latch = CompletionLatch()
        var outcomes: [String] = []
        latch.completeOnce { outcomes.append("expired") }
        latch.completeOnce { outcomes.append("completed") }
        #expect(outcomes == ["expired"])
    }

    @Test("本体が先に通知したら、期限切れ側は通知しない")
    func completionWinsOverExpiration() {
        let latch = CompletionLatch()
        var outcomes: [String] = []
        latch.completeOnce { outcomes.append("completed") }
        latch.completeOnce { outcomes.append("expired") }
        #expect(outcomes == ["completed"])
    }

    @Test("reset で次の実行分を受け付ける")
    func resetAllowsNextRun() {
        let latch = CompletionLatch()
        var calls = 0
        latch.completeOnce { calls += 1 }
        latch.reset()
        #expect(!latch.hasCompleted)
        #expect(latch.completeOnce { calls += 1 })
        #expect(calls == 2)
    }
}

/// ⚠️ 重い処理のルーチンは「アプリは非アクティブ」を前提にゲートを開ける。
/// フォアグラウンドから叩くデバッグ実行でこのフラグを立てっぱなしにすると、
/// 次の scenePhase 変化まで**ユーザー操作中でも重い処理が走り続ける**（レビュー指摘）。
@Suite("BackgroundYield.isAppActive の一時変更")
@MainActor
struct AppActiveRestoreTests {

    /// 実運用と同じ形（保存 → 変更 → defer で復元）を模した最小の関数。
    private func runWithInactive(restore: Bool, body: () -> Void) {
        let previous = BackgroundYield.isAppActive
        BackgroundYield.isAppActive = false
        defer { if restore { BackgroundYield.isAppActive = previous } }
        body()
    }

    @Test("復元ありなら、実行後に元の値へ戻る（前面デバッグ実行）")
    func restoresPreviousValue() {
        BackgroundYield.isAppActive = true
        defer { BackgroundYield.isAppActive = true }

        runWithInactive(restore: true) {
            #expect(!BackgroundYield.isAppActive, "実行中は非アクティブ扱いであること")
        }
        #expect(BackgroundYield.isAppActive,
                "前面に戻っているのに非アクティブ扱いが残る（操作中でも重い処理が走る）")
    }

    @Test("復元なしなら非アクティブのまま（実 BGTask）")
    func keepsInactiveForRealBackgroundRun() {
        BackgroundYield.isAppActive = true
        defer { BackgroundYield.isAppActive = true }

        runWithInactive(restore: false) {}
        #expect(!BackgroundYield.isAppActive)
    }
}
