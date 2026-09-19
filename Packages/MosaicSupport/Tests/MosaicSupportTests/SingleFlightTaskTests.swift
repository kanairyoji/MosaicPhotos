import Foundation
import Testing
@testable import MosaicSupport

/// 本体が終わるまで外から握っておくための小さな門。
///
/// ⚠️ **`open()` が `wait()` より先に来ても取りこぼさない**こと。素の
/// `withCheckedContinuation` を直に使うと、タスク本体がまだ始まっていない時点で
/// `resume` しようとして**永久に待つ**（このテストで実際にハングさせた）。
@MainActor
private final class TestGate {
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

/// `SingleFlightTask`（ADR-198）。手書きで 24 か所に散っていた「1 本だけ走らせる／世代ガード／
/// 走行中の要求を 1 回だけ拾い直す」を 1 つにまとめたもの。
/// **過去に実際に踏んだ 2 つのバグを回帰として固定する。**
@Suite("SingleFlightTask（ADR-198）", .serialized)
@MainActor
struct SingleFlightTaskTests {

    @Test("走行中に start しても二重に走らない")
    func startIsSingleFlight() async {
        let flight = SingleFlightTask()
        let gate = TestGate()
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
        let first = TestGate()
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
        let stale = TestGate()
        let fresh = TestGate()

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
        let gate = TestGate()
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
        let gate = TestGate()
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

        let stale = TestGate()
        flight.start { await stale.wait() }
        flight.restart { }                 // 旧タスクを明け渡す
        stale.open()                        // 旧タスクが遅れて終わる
        await flight.waitUntilIdle()

        // true → (restart では走り続けているので通知なし) → false の 2 回だけ。
        #expect(events == [true, false], "余計な状態変化が飛んでいる: \(events)")
    }
}

/// `waitUntilIdle()` は**止めた作業も待つ**（ADR-198・レビュー前の自己点検で見つけた退行）。
///
/// `cancel()` は「降りてくれ」と伝えるだけで、実行中の 1 単位は最後まで走る。
/// `PeopleEngine.reset` は「本当に止まってからストアを消す」必要があり、待たずに消すと
/// `FaceTagger.isRunning` が残って次のスキャンが無言で skip される。
@Suite("SingleFlightTask の停止待ち", .serialized)
@MainActor
struct SingleFlightWaitTests {

    @Test("回帰: stop したあとの waitUntilIdle は、止めた作業が終わるまで返らない")
    func waitsForTheStoppedWork() async {
        let flight = SingleFlightTask()
        let gate = TestGate()
        var finished = false
        flight.start {
            await gate.wait()
            finished = true          // キャンセルを見たあとの後始末（ストアの書き込み停止に相当）
        }
        flight.stop()
        #expect(!finished)

        gate.open()                  // 止めた作業がようやく降りる
        await flight.waitUntilIdle()
        #expect(finished, "止めた作業の完了を待たずに返った（ストアを消す前に止まっていない）")
    }

    @Test("回帰: restart のあとの waitUntilIdle は、明け渡した方も新しい方も待つ")
    func waitsForBothTheRetiredAndTheCurrent() async {
        let flight = SingleFlightTask()
        let old = TestGate(), fresh = TestGate()
        var done: [String] = []
        flight.start { await old.wait(); done.append("old") }
        flight.restart { await fresh.wait(); done.append("new") }
        old.open()
        fresh.open()
        await flight.waitUntilIdle()
        #expect(done.sorted() == ["new", "old"], "待ち漏れ: \(done)")
    }
}

/// レビューが拾った 3 件の回帰（ADR-198 のレビュー・2026-09-19）。
@Suite("SingleFlightTask のレビュー回帰", .serialized)
@MainActor
struct SingleFlightReviewRegressionTests {

    /// 素の `Task { }` は**呼び出し元の優先度を引き継ぐ**。背景トリクルが
    /// 駆動役（`.userInitiated`）や SwiftUI の `.task` から起こされると昇格し、
    /// UI 操作と CPU を奪い合う（「QoS は .background」という方針が消える）。
    @Test("回帰: 指定した優先度で走る（素の Task は呼び出し元を引き継ぐ）")
    func runsAtTheRequestedPriority() async {
        let flight = SingleFlightTask()
        // ⚠️ `waitUntilIdle()` で待つと、待つ側（.medium）の優先度が**待たれる側へ昇格**して
        // しまい、指定した優先度を測れない。眠って様子を見る（依存を作らない）。
        var observed: TaskPriority?
        flight.start(priority: .background) { observed = Task.currentPriority }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(observed == .background, "指定した優先度で走っていない: \(String(describing: observed))")

        var inherited: TaskPriority?
        flight.start { inherited = Task.currentPriority }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(inherited != nil && inherited != .background, "優先度を指定していないのに .background になっている（テストが何も守っていない）")
    }

    /// `stop()` は予約を捨てるのに `restart()` は残す、という非対称は罠
    /// （捨てたはずの作業が明け渡しのあとに蘇る）。
    @Test("回帰: restart は予約も捨てる（stop と対称）")
    func restartClearsPending() async {
        let flight = SingleFlightTask()
        let gate = TestGate()
        var ran: [String] = []
        flight.start { await gate.wait() }
        flight.coalesce { ran.append("stale") }
        flight.restart { ran.append("fresh") }
        gate.open()
        await flight.waitUntilIdle()
        #expect(ran == ["fresh"], "明け渡した実行の予約が蘇った: \(ran)")
    }
}

/// `DebouncedTask` は body の実行中も重複を防ぐ（レビュー指摘）。
@Suite("DebouncedTask の重複防止", .serialized)
@MainActor
struct DebouncedTaskOverlapTests {

    /// 条件が成立するまで待つ（上限つき）。
    /// ⚠️ `Task.yield()` では**静止時間（`Task.sleep`）は進まない**ので実時間で待つ。
    /// これは「速いこと」の判定ではなく「起きるはずのことが起きるまで待つ」ので、
    /// 負荷の高い CI で上限に余裕があるかぎり揺れない（ADR-119）。
    private func waitUntil(_ condition: () -> Bool, limitMs: Int = 2_000) async {
        for _ in 0..<(limitMs / 5) {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// `loadPeople()` は 600〜1000ms、静止時間は 700ms。実行中に次の要求が来るのは日常的で、
    /// そこで 2 本目が走ると「間引きのために入れた仕組みが重複実行を許す」ことになる。
    ///
    /// ⚠️ 旧版はここで `gate.open()` を 2 本目の予約直後に呼んでいたため、1 本目が
    /// 静止時間より先に終わってしまい、**欠陥があっても通った**（レビュー指摘）。
    /// 関門は「2 本目が走り出せたはず」の時間を過ぎるまで閉じたままにする。
    @Test("回帰: body の実行中に来た要求で 2 本目を起こさない")
    func doesNotStartASecondRunWhileTheBodyIsRunning() async {
        let debounced = DebouncedTask(quietMilliseconds: 10)
        let gate = TestGate()
        var running = 0
        var maxConcurrent = 0
        var entered: [String] = []

        debounced.schedule {
            entered.append("first")
            running += 1; maxConcurrent = max(maxConcurrent, running)
            await gate.wait()
            running -= 1
        }
        // fixture の前提を**確かめる**: 1 本目が本当に body へ入っていること（ADR-119）。
        await waitUntil { !entered.isEmpty }
        #expect(entered == ["first"], "1 本目が body に入っていない＝前提が成立していない")

        debounced.schedule {
            entered.append("second")
            running += 1; maxConcurrent = max(maxConcurrent, running); running -= 1
        }
        // 静止時間 10ms に対して 300ms 待つ（30 倍の余裕）。欠陥があればここで 2 本目が走る。
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(maxConcurrent == 1, "1 本目の実行中に 2 本目が走った（同時 \(maxConcurrent) 本）")

        gate.open()
        await debounced.waitUntilIdle()
        #expect(entered == ["first", "second"], "順に 1 回ずつ走らなかった: \(entered)")
        #expect(maxConcurrent == 1)
    }

    /// 回帰: **終わりかけの古い実行が、新しい予約のハンドルを消さない**。
    /// 消すと `waitUntilIdle()` が「もう無い」と見て即座に返り、`cancel()` も空振りする
    /// ——取り消せない実行が積み上がる入口になっていた（レビュー指摘）。
    @Test("回帰: 古い実行が新しい予約のハンドルを消さない")
    func finishingRunDoesNotDiscardTheNewerHandle() async {
        let debounced = DebouncedTask(quietMilliseconds: 10)
        let gate = TestGate()
        var ran: [String] = []

        debounced.schedule {
            ran.append("first-begin")
            await gate.wait()
            ran.append("first-end")
        }
        await waitUntil { !ran.isEmpty }
        #expect(ran == ["first-begin"], "1 本目が body に入っていない＝前提が成立していない")

        debounced.schedule { ran.append("second") }
        gate.open()
        // 1 本目が**終わりきる**まで待つ。ハンドルを消す退行はこの瞬間に起きる。
        await waitUntil { ran.contains("first-end") }
        #expect(ran.contains("first-end"), "1 本目が終わっていない＝前提が成立していない")

        // ハンドルが残っていれば `waitUntilIdle()` は 2 本目を待つ。消えていれば
        // 「もう無い」と見て即座に返り、2 本目は裏で走り続ける。
        await debounced.waitUntilIdle()
        #expect(ran.contains("second"),
                "2 本目を待たずに idle になった（ハンドルが消えている）: \(ran)")
    }
}
