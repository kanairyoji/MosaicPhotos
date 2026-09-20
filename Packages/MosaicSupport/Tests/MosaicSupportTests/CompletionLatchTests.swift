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

    /// 回帰: **スコープの中で外から画面状態が変わったら、書き戻さない**（レビュー 11 周目）。
    ///
    /// この変数はアプリ側の `onChange` も書いており、そちらは**変化したときだけ**動く。
    /// 窓の実行中に前面へ戻ると `.active` が入る。そこでスコープが `.background` を
    /// 書き戻すと**前面なのに背面扱い**で固定され、`onChange` は次の遷移まで来ないので
    /// アプリを背面へ落とすまで直らない。前面・アイドル・電源・回線のどの契機でも
    /// 解析が起きなくなり、UI への譲りも効かなくなる。
    @Test("回帰: 実行中に前面へ戻ったら、抜けるときに背面へ戻さない")
    func doesNotClobberAPhaseChangedFromOutside() async {
        BackgroundYield.setScenePhase(.background)
        defer { BackgroundYield.setScenePhase(.active) }

        await BackgroundYield.withScenePhase(.background) {
            // 窓の最中にユーザーがアプリを開いた（アプリ側の onChange 相当）。
            BackgroundYield.setScenePhase(.active)
        }
        #expect(BackgroundYield.scenePhase == .active,
                "外から入った前面を古い値で上書きした（以後ずっと背面扱いになる）")
    }

    /// 回帰: 外から入った値が**たまたまスコープと同じ**でも、書き戻さないこと。
    ///
    /// ⚠️ 値は「誰が書いたか」を表さない。12 周目に「値が変わっていなければ戻す」で直したが、
    /// それだと外から同じ値が書かれたときに「誰も触っていない」と誤判定して上書きする
    /// ——前面のまま背面扱いで固定される事故の、ちょうど裏返し。
    /// 例: デバッグ実行（前面で開始・中で背面扱い）の最中に画面を消すと、
    /// アプリ側が `.background` を書く。抜けるときに `.active` へ戻すと、
    /// **画面を消しているのに前面扱い**になり、重い処理が課されたまま止まる。
    @Test("回帰: 外から同じ値が書かれても、抜けるときに書き戻さない")
    func doesNotRestoreWhenOutsideWroteTheSameValue() async {
        BackgroundYield.setScenePhase(.active)
        defer { BackgroundYield.setScenePhase(.active) }

        await BackgroundYield.withScenePhase(.background) {
            // 実行中に画面が消えた（アプリ側の onChange 相当・**同じ値**）。
            BackgroundYield.setScenePhase(.background)
        }
        #expect(BackgroundYield.scenePhase == .background,
                "外から入った背面を、同じ値だからと前面へ戻した（消灯中なのに前面扱い）")
    }

    @Test("回帰: 外から同じ段が書かれても、抜けるときに段を戻さない")
    func doesNotRestoreWhenOutsideWroteTheSameExemption() async {
        BackgroundYield.setExemption(.none)
        defer { BackgroundYield.setExemption(.none) }

        await BackgroundYield.withExemption(.debug) {
            BackgroundYield.setExemption(.debug)   // 設定画面でトグルを ON にした
        }
        #expect(BackgroundYield.exemption == .debug,
                "トグルが ON なのにデバッグ実行の後始末が段を下げた")
    }

    /// 回帰: **片方への書き込みが、もう片方のスコープの後始末を止めない**こと。
    ///
    /// ⚠️ 13 周目は「外からの書き込み回数」を 1 つの数で兼ねたが、それだと
    /// 画面状態への書き込みが免除のスコープを止め、免除への書き込みが画面状態の
    /// スコープを止める。実測での帰結:
    /// - デバッグ実行中に画面を消す → 免除が `.debug` のまま固定＝全ゲートが外れる
    /// - デバッグ実行中に「今すぐ解析」 → 前面なのに背面扱いのまま固定
    /// 本番で両方のスコープが重なるのは `debugRunNow`（免除の中で画面状態）。
    @Test("回帰: 画面状態への書き込みが、免除の後始末を止めない")
    func scenePhaseWriteDoesNotBlockExemptionRestore() async {
        BackgroundYield.setScenePhase(.active)
        BackgroundYield.setExemption(.none)
        defer { BackgroundYield.setScenePhase(.active); BackgroundYield.setExemption(.none) }

        await BackgroundYield.withExemption(.debug) {
            await BackgroundYield.withScenePhase(.background) {
                BackgroundYield.setScenePhase(.background)   // 実行中に画面を消した
            }
        }
        #expect(BackgroundYield.exemption == .none,
                "画面状態を書いただけで免除が戻らなくなった（全ゲートが外れたまま固定）")
        #expect(BackgroundYield.scenePhase == .background, "外から入った背面は残ること")
    }

    @Test("回帰: 免除への書き込みが、画面状態の後始末を止めない")
    func exemptionWriteDoesNotBlockScenePhaseRestore() async {
        BackgroundYield.setScenePhase(.active)
        BackgroundYield.setExemption(.none)
        defer { BackgroundYield.setScenePhase(.active); BackgroundYield.setExemption(.none) }

        await BackgroundYield.withScenePhase(.background) {
            BackgroundYield.setExemption(.boost)   // 実行中に「今すぐ解析」を押した
        }
        #expect(BackgroundYield.scenePhase == .active,
                "免除を書いただけで画面状態が戻らなくなった（前面なのに背面扱いで固定）")
        #expect(BackgroundYield.exemption == .boost, "外から入ったブーストは残ること")
    }

    @Test("回帰: 実行中にブーストが始まったら、抜けるときに段を下げない")
    func doesNotClobberAnExemptionChangedFromOutside() async {
        BackgroundYield.setExemption(.none)
        defer { BackgroundYield.setExemption(.none) }

        await BackgroundYield.withExemption(.debug) {
            BackgroundYield.setExemption(.boost)   // 実行中に「今すぐ解析」が始まった
        }
        #expect(BackgroundYield.exemption == .boost,
                "走っているブーストの免除をデバッグ実行の後始末が取り消した")
    }
}
