import Foundation
import Testing
@testable import MosaicSupport

/// 中断（suspend）を跨いだ計測値を捨てる番人。
///
/// ⚠️ `PROCESS SUSPENDED` の行は出るのに**スパンは素通し**だった時期があり、実機ログの
/// `people.load.tuning 1612569.4ms`（27 分）を「ハング」と読み違えかけた（diagnostics-69）。
/// 判定そのものをテストで固定する。
@Suite("中断を跨いだ計測の無効化")
struct ProcessSuspensionTests {

    @Test("復帰より前に始まったスパンは無効、あとに始まったスパンは有効")
    func spansAcrossSuspensionAreInvalidated() {
        ProcessSuspension.simulateSuspensionForTesting()
        #expect(ProcessSuspension.spanned(lastMs: 60_000),
                "中断より前に始まった計測は壁時計で汚染されている")

        // 復帰から十分に間を空けて始まった短い計測は、そのまま有効でなければならない
        //（すべて捨ててしまうと、今度は背景処理を一切測れなくなる）。
        Thread.sleep(forTimeInterval: 0.05)
        #expect(ProcessSuspension.spanned(lastMs: 5) == false,
                "復帰後に始まった計測まで捨てると、背景の遅さが見えなくなる")
    }

    @Test("所要 0 は判定しない（開始時刻を逆算できない）")
    func zeroLengthSpanIsNeverInvalidated() {
        ProcessSuspension.simulateSuspensionForTesting()
        #expect(ProcessSuspension.spanned(lastMs: 0) == false)
    }
}
