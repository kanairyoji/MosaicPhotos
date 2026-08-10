import Foundation
import Testing
@testable import MosaicSupport

/// メイン応答性センサーの前面/背面の分類（ADR-82）。
/// 背面の停止は OS の throttle であって体感とは無関係なので、集計・即時ログから外す。
@Suite("MainThreadWatchdog", .serialized)
struct MainThreadWatchdogTests {

    /// 共有インスタンスを既知の状態にする（前回テストの残りを捨てる）。
    private func reset() {
        MainThreadWatchdog.shared.setAppActive(true)
        _ = MainThreadWatchdog.shared.flushSummary()
    }

    @Test("前面のサンプルは集計に入る（pings と max に反映）")
    func foregroundSamplesCounted() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(30)
        w.record(600)
        let summary = w.flushSummary()
        #expect(summary?.contains("pings=2") == true)
        #expect(summary?.contains("max=600") == true)
        #expect(summary?.contains("bgStalls") == false)
    }

    @Test("背面のサンプルは集計に入らず bgStalls として別枠で数える")
    func backgroundSamplesSeparated() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        w.record(28_513)          // 実機ログにあった 28.5 秒の背面停止
        w.record(30)              // しきい値未満は数えない（ノイズ）
        let summary = w.flushSummary()
        // 本体の集計（pings/max）は汚さない＝前面の実力が読める。
        #expect(summary == "main: (background) bgStalls=1")
        w.setAppActive(true)
    }

    @Test("flush で状態がリセットされる（前面・背面とも）")
    func flushResets() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(600)
        _ = w.flushSummary()
        #expect(w.flushSummary() == nil)

        w.setAppActive(false)
        w.record(600)
        _ = w.flushSummary()
        #expect(w.flushSummary() == nil)
        w.setAppActive(true)
    }

    @Test("前面と背面が混在しても、前面ぶんだけが max に出る")
    func mixedSamples() {
        reset()
        let w = MainThreadWatchdog.shared
        w.record(900)             // 前面
        w.setAppActive(false)
        w.record(20_000)          // 背面（max を汚さないこと）
        w.setAppActive(true)
        w.record(100)             // 前面
        let summary = w.flushSummary()
        #expect(summary?.contains("max=900") == true)
        #expect(summary?.contains("pings=2") == true)
        #expect(summary?.contains("bgStalls=1") == true)
    }

    // MARK: - 復帰をまたいだ ping（ADR-97）

    /// 実機 diagnostics-40〜43 の回帰: 重い処理が**一つも走っていない**復帰
    ///（`prewarm cancelled at 0/314`・`model load skipped` ×4・`infer=0ms`）で
    /// `hang main=11041ms` が記録されていた。背面で送った ping が復帰の瞬間に返ると
    /// 「返答時は前面」なので前面ハングとして数えられ、中断/throttle の待ちが体感の数字を汚す。
    @Test("背面で送って復帰後に返った ping は前面ハングに数えない")
    func pingSpanningResumeIsNotForegroundHang() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        let sentWhileBackground = DispatchTime.now().uptimeNanoseconds
        w.setAppActive(true)      // ここで復帰＝この時刻より前の ping は対象外
        w.record(11_041, startedNs: sentWhileBackground)

        let summary = w.flushSummary()
        #expect(summary?.contains("max=11041") != true, "中断待ちが前面の max を汚している")
        #expect(summary?.contains("bgStalls=1") == true, "背面側の参考値としては残すこと")
    }

    @Test("復帰後に送った ping は通常どおり前面ハングとして数える")
    func pingAfterResumeStillCounted() {
        reset()
        let w = MainThreadWatchdog.shared
        w.setAppActive(false)
        w.setAppActive(true)
        let sentWhileForeground = DispatchTime.now().uptimeNanoseconds
        w.record(700, startedNs: sentWhileForeground)

        let summary = w.flushSummary()
        #expect(summary?.contains("max=700") == true, "前面で完結した停止まで捨ててはいけない")
        #expect(summary?.contains("pings=1") == true)
    }
}
