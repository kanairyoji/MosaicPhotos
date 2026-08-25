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
        let token = latch.begin()
        var calls = 0
        #expect(latch.completeOnce(token) { calls += 1 })
        #expect(!latch.completeOnce(token) { calls += 1 }, "2 回目も通ってしまう（二重通知）")
        #expect(calls == 1)
        #expect(latch.hasCompleted)
    }

    /// 期限切れ → 本体の終了、という実際の順序。
    @Test("期限切れが先に通知したら、本体側は通知しない")
    func expirationWinsOverCompletion() {
        let latch = CompletionLatch()
        let token = latch.begin()
        var outcomes: [String] = []
        latch.completeOnce(token) { outcomes.append("expired") }
        latch.completeOnce(token) { outcomes.append("completed") }
        #expect(outcomes == ["expired"])
    }

    @Test("本体が先に通知したら、期限切れ側は通知しない")
    func completionWinsOverExpiration() {
        let latch = CompletionLatch()
        let token = latch.begin()
        var outcomes: [String] = []
        latch.completeOnce(token) { outcomes.append("completed") }
        latch.completeOnce(token) { outcomes.append("expired") }
        #expect(outcomes == ["completed"])
    }

    @Test("次の実行（新しい世代）は改めて 1 回だけ通す")
    func nextRunGetsItsOwnSlot() {
        let latch = CompletionLatch()
        var calls = 0
        latch.completeOnce(latch.begin()) { calls += 1 }
        let second = latch.begin()
        #expect(!latch.hasCompleted)
        #expect(latch.completeOnce(second) { calls += 1 })
        #expect(calls == 2)
    }

    /// ⚠️ レビュー指摘の本命。A の期限切れ通知 → B 開始 → **遅れて A 本体が通知**、という順序。
    @Test("前の実行から遅れて来た通知は、新しい実行の枠を奪わない")
    func staleCompletionDoesNotStealNextRunSlot() {
        let latch = CompletionLatch()
        var outcomes: [String] = []

        let runA = latch.begin()
        latch.completeOnce(runA) { outcomes.append("A-expired") }   // A: 期限切れで通知済み

        let runB = latch.begin()                                     // B: 次の BGTask が開始
        #expect(!latch.completeOnce(runA) { outcomes.append("A-late") },
                "旧世代の遅れた通知が通ると、A が二重に setTaskCompleted を呼ぶ")
        #expect(latch.completeOnce(runB) { outcomes.append("B-completed") },
                "B の正規の完了通知が黙って捨てられる（OS へ完了を伝えられない）")

        #expect(outcomes == ["A-expired", "B-completed"])
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
