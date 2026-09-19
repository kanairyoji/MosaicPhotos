import Foundation
import Testing
@testable import MosaicSupport

/// `SingleFlightTask`（ADR-198）。手書きで 24 か所に散っていた「1 本だけ走らせる／世代ガード／
/// 走行中の要求を 1 回だけ拾い直す」を 1 つにまとめたもの。
/// **過去に実際に踏んだ 2 つのバグを回帰として固定する。**
@Suite("SingleFlightTask（ADR-198）", .serialized)
@MainActor
struct SingleFlightTaskTests {

    /// 本体が終わるまで外から握っておくための小さな門。
    private final class Gate {
        private var cont: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { cont = $0 }
        }
        func open() {
            opened = true
            cont?.resume()
            cont = nil
        }
    }

    @Test("走行中に start しても二重に走らない")
    func startIsSingleFlight() async {
        let flight = SingleFlightTask()
        let gate = Gate()
        var runs = 0

        #expect(flight.start { runs += 1; await gate.wait() })
        #expect(flight.isRunning)
        #expect(flight.start { runs += 1 } == false, "走行中の start は何もしない")

        gate.open()
        await flight.waitUntilIdle()
        #expect(runs == 1)
        #expect(!flight.isRunning)
    }

    @Test("restart は走行中でも明け渡させて始め直す（ADR-95・窓の先頭）")
    func restartPreempts() async {
        let flight = SingleFlightTask()
        let first = Gate()
        var order: [String] = []

        flight.start { order.append("first-begin"); await first.wait(); order.append("first-end") }
        flight.restart { order.append("second") }
        #expect(flight.isRunning)

        first.open()
        await flight.waitUntilIdle()
        #expect(order.contains("second"), "始め直した方が走っていない")
    }

    /// レビュー指摘の回帰: **A をキャンセル後に B が始まり、その後 A が終了したときに、
    /// A が B のハンドル／実行中フラグを消してしまう**（`GenerationHandle` 新設の理由）。
    @Test("回帰: 明け渡した旧タスクが遅れて終わっても、後続の実行中フラグを落とさない")
    func staleTaskDoesNotClobberTheNewOne() async {
        let flight = SingleFlightTask()
        let stale = Gate()
        let fresh = Gate()

        flight.start { await stale.wait() }          // A
        flight.restart { await fresh.wait() }        // B（A は明け渡し）
        #expect(flight.isRunning)

        stale.open()                                  // A が遅れて終わる
        await Task.yield(); await Task.yield()
        #expect(flight.isRunning, "旧タスクの末尾処理が後続の実行中フラグを落とした")

        fresh.open()
        await flight.waitUntilIdle()
        #expect(!flight.isRunning)
    }

    /// レビュー指摘の回帰: **走行中に来た要求を捨てると、本物の変化が消える**
    /// （実例: 数え直しの最中に解析が終わり、完了直後の数字が凍る）。
    @Test("回帰: 走行中に来た要求は捨てずに 1 回だけ拾い直す")
    func coalescedRequestIsNotDropped() async {
        let flight = SingleFlightTask()
        let gate = Gate()
        var runs = 0

        flight.start { runs += 1; await gate.wait() }
        flight.coalesce { runs += 1 }
        flight.coalesce { runs += 1 }   // 2 つ以上来ても、畳まれるのは 1 回ぶん

        gate.open()
        await flight.waitUntilIdle()
        #expect(runs == 2, "拾い直しが 0 回（捨てた）か 3 回（畳めていない）")
        #expect(!flight.isRunning)
    }

    @Test("走行中でなければ coalesce はすぐ始める")
    func coalesceRunsImmediatelyWhenIdle() async {
        let flight = SingleFlightTask()
        var runs = 0
        flight.coalesce { runs += 1 }
        await flight.waitUntilIdle()
        #expect(runs == 1)
    }

    @Test("stop は走行中の作業も予約も止める")
    func stopClearsPending() async {
        let flight = SingleFlightTask()
        let gate = Gate()
        var runs = 0

        flight.start { runs += 1; await gate.wait() }
        flight.coalesce { runs += 1 }
        flight.stop()
        #expect(!flight.isRunning)

        gate.open()
        await Task.yield(); await Task.yield()
        #expect(runs == 1, "stop したのに予約が走った")
    }

    @Test("本体がキャンセルを見て抜けても、実行中フラグは必ず戻る")
    func cancellationStillClearsTheFlag() async {
        let flight = SingleFlightTask()
        flight.start {
            while !Task.isCancelled { await Task.yield() }
        }
        flight.stop()
        await flight.waitUntilIdle()
        #expect(!flight.isRunning)
    }
}

/// `DebouncedTask`（ADR-198）。連続する要求を 1 回にまとめる。
@Suite("DebouncedTask（ADR-198）", .serialized)
@MainActor
struct DebouncedTaskTests {

    @Test("連続した要求は 1 回にまとまる（1 分に 30 回の再読込＝ハング 30 回を防ぐ）")
    func rapidRequestsCollapseIntoOne() async {
        let debounced = DebouncedTask(quietMilliseconds: 20)
        var runs = 0
        for _ in 0..<5 { debounced.schedule { runs += 1 } }
        await debounced.waitUntilIdle()
        #expect(runs == 1)
    }

    @Test("静止してから走る（要求の直後には走らない）")
    func waitsForQuiet() async {
        let debounced = DebouncedTask(quietMilliseconds: 50)
        var runs = 0
        debounced.schedule { runs += 1 }
        #expect(runs == 0, "要求と同時に走ってしまっている（間引きになっていない）")
        #expect(debounced.isScheduled)
        await debounced.waitUntilIdle()
        #expect(runs == 1)
    }

    @Test("cancel すれば走らない")
    func cancelPreventsTheRun() async {
        let debounced = DebouncedTask(quietMilliseconds: 20)
        var runs = 0
        debounced.schedule { runs += 1 }
        debounced.cancel()
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(runs == 0)
        #expect(!debounced.isScheduled)
    }
}

/// `onStateChange`（鏡写し用）。`BackgroundActivityMonitor` のフラグはここから同期する。
@Suite("SingleFlightTask の状態通知", .serialized)
@MainActor
struct SingleFlightStateChangeTests {

    @Test("開始と終了で 1 回ずつ通知が来る")
    func notifiesOnceEachWay() async {
        let flight = SingleFlightTask()
        var events: [Bool] = []
        flight.onStateChange = { events.append($0) }
        flight.start { }
        await flight.waitUntilIdle()
        #expect(events == [true, false])
    }

    /// 回帰: 明け渡した旧タスクが遅れて終わっても、**走り続けている後続の鏡写しを落とさない**
    /// （本体の `defer` で鏡写しすると、ここで false が飛んでしまう）。
    @Test("回帰: 明け渡しのあと、旧タスクの終了で false を飛ばさない")
    func staleCompletionDoesNotEmitFalse() async {
        let flight = SingleFlightTask()
        var events: [Bool] = []
        flight.onStateChange = { events.append($0) }

        var release: (() -> Void)?
        flight.start { await withCheckedContinuation { c in release = { c.resume() } } }
        flight.restart { }                 // 旧タスクを明け渡す
        release?()                          // 旧タスクが遅れて終わる
        await flight.waitUntilIdle()

        // true → (restart では走り続けているので通知なし) → false の 2 回だけ。
        #expect(events == [true, false], "余計な状態変化が飛んでいる: \(events)")
    }
}
