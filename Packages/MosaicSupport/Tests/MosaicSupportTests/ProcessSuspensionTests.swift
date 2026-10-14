import Foundation
import Testing
@testable import MosaicSupport

/// 中断（suspend）を跨いだ計測値を捨てる番人。
///
/// ⚠️ `PROCESS SUSPENDED` の行は出るのに**スパンは素通し**だった時期があり、実機ログの
/// `people.load.tuning 1612569.4ms`（27 分）を「ハング」と読み違えかけた（diagnostics-69）。
/// 判定そのものをテストで固定する。
@Suite("中断を跨いだ計測の無効化", .serialized)
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

    @Test("復帰した直後、タイマーが中断を数える前でも「跨いだ」と答える")
    func resumeIsVisibleBeforeTheTimerCountsIt() {
        let epoch = ProcessSuspension.epoch
        // ⚠️ 2 つの結果を区別できる fixture か（ADR-268）: 遅れていなければ跨いでいない。
        #expect(ProcessSuspension.didSuspend(since: epoch) == false)
        ProcessSuspension.withOverdueTimerForTesting {
            #expect(ProcessSuspension.epoch == epoch, "まだ数えていない一瞬を作れていること")
            #expect(ProcessSuspension.didSuspend(since: epoch),
                    "停止の前に投げた通信が復帰で落ちた回を、本物の通信障害と読まないため（diagnostics-109）")
        }
        #expect(ProcessSuspension.didSuspend(since: epoch) == false, "元に戻っていること")
    }
}
