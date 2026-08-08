import Foundation
import Testing
@testable import PerceptionCore

/// 背景トリクルの譲り挙動（ADR-79: 譲り開始フックで重いモデルを解放する）。
@Suite("BackgroundTrickle")
@MainActor
struct BackgroundTrickleTests {

    /// 呼び出し回数を数えるだけの可変ホルダ（@MainActor 上で使う）。
    @MainActor
    final class Counter {
        var pauseChecks = 0
        var pauseBegins = 0
        var processed: [Int] = []
    }

    @Test("譲りに入ったら onPauseBegin が 1 回だけ呼ばれる（待機中は繰り返さない）")
    func pauseBeginFiresOnce() async {
        let c = Counter()
        // 最初の 3 回は「譲れ」、以降は再開。
        await BackgroundTrickle.waitWhilePaused({
            c.pauseChecks += 1
            return c.pauseChecks <= 3
        }, onPauseBegin: { c.pauseBegins += 1 })

        #expect(c.pauseBegins == 1)      // 0.3s ごとの待機中に何度も解放を呼ばない
        #expect(c.pauseChecks == 4)      // 4 回目で false → 抜ける
    }

    @Test("譲りが発生しなければ onPauseBegin は呼ばれない")
    func pauseBeginNotFiredWhenRunning() async {
        let c = Counter()
        await BackgroundTrickle.waitWhilePaused({ false },
                                                onPauseBegin: { c.pauseBegins += 1 })
        #expect(c.pauseBegins == 0)
    }

    @Test("run: 譲りは 1 単位ごとに確認され、フックは譲りのたびに 1 回立つ")
    func runFiresPauseHookPerPause() async {
        let c = Counter()
        var pauseNext = false
        await BackgroundTrickle.run(
            maxBatches: 1,
            betweenBatchNs: 0,
            shouldPause: {
                // 各単位の前に 1 度だけ譲る（次の確認では false に戻す）。
                defer { pauseNext = false }
                return pauseNext
            },
            onPauseBegin: { c.pauseBegins += 1 },
            unitPerfLabel: "test.unitMs",
            nextBatch: { index in index == 0 ? [1, 2, 3] : [] },
            processUnit: { unit in
                c.processed.append(unit)
                pauseNext = true      // 次の単位の前に 1 回譲らせる
                return unit
            },
            commitBatch: { _, _, _ in .stop })

        #expect(c.processed == [1, 2, 3])
        // 1 単位目は譲らず、2・3 単位目の前で 1 回ずつ譲る。
        #expect(c.pauseBegins == 2)
    }
}
