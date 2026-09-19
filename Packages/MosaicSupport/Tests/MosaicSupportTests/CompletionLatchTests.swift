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

/// 画面状態の一時変更は**スコープ**で入る（ADR-196）。
///
/// 以前は `BackgroundYield.isAppActive` を手で書き換え、`restoreAppActive` という引数で
/// 後始末していた。戻し忘れると「次の scenePhase 変化までユーザー操作中でも重い処理が走り続ける」
/// （レビュー指摘）。スコープなら戻し忘れが書けない。
@Suite("画面状態のスコープ（withScenePhase）", .serialized)
@MainActor
struct ScenePhaseScopeTests {

    @Test("抜けたら必ず元へ戻る")
    func restoresOnExit() async {
        BackgroundYield.setScenePhase(.active)
        defer { BackgroundYield.setScenePhase(.active) }

        await BackgroundYield.withScenePhase(.background) {
            #expect(BackgroundYield.scenePhase == .background, "実行中は背面扱いであること")
        }
        #expect(BackgroundYield.scenePhase == .active,
                "前面に戻っているのに背面扱いが残る（操作中でも重い処理が走る）")
    }

    @Test("入れ子でも元へ戻る")
    func restoresWhenNested() async {
        BackgroundYield.setScenePhase(.active)
        defer { BackgroundYield.setScenePhase(.active) }

        await BackgroundYield.withScenePhase(.background) {
            await BackgroundYield.withScenePhase(.inactive) {
                #expect(BackgroundYield.scenePhase == .inactive)
            }
            #expect(BackgroundYield.scenePhase == .background)
        }
        #expect(BackgroundYield.scenePhase == .active)
    }

    @Test("免除の段もスコープで戻る")
    func exemptionScopeRestores() async {
        BackgroundYield.setExemption(.none)
        await BackgroundYield.withExemption(.debug) {
            #expect(BackgroundYield.exemption == .debug)
        }
        #expect(BackgroundYield.exemption == .none)
    }
}
