import XCTest
@testable import PerceptionCore

/// ANE 直列化ゲート（`MLInferenceGate`）の並行処理テスト。
/// 実機・シミュレータ不要（純粋な Swift 並行処理なので macOS の `swift test` で回る）。
///
/// テストは `.shared` ではなく**新しいインスタンス**を使う。シングルトンだと他テストと状態を共有し、
/// 待機列の順序を検証できないため。
final class MLInferenceGateTests: XCTestCase {

    /// 実行順を記録する。
    private actor Recorder {
        private(set) var order: [String] = []
        func add(_ label: String) { order.append(label) }
    }

    /// ゲートを保持したまま「解放してよい」の合図を待つホルダー。
    /// 合図は continuation ではなく `AsyncStream` で渡す（resume 漏れによるハングを避ける）。
    private struct Holder {
        let task: Task<Void, Never>
        let release: () -> Void
    }

    /// ゲートを取って保持し続けるタスクを起こし、**確実に保持した状態**で返す。
    private func startHolder(_ gate: MLInferenceGate) async -> Holder {
        let (acquired, acquiredCont) = AsyncStream<Void>.makeStream()
        let (permit, permitCont) = AsyncStream<Void>.makeStream()
        let task = Task {
            await gate.run {
                acquiredCont.yield(())
                acquiredCont.finish()
                for await _ in permit { break }   // 解放の合図まで保持し続ける
            }
        }
        for await _ in acquired { break }         // ここを抜けた時点でゲートは保持されている
        return Holder(task: task, release: { permitCont.finish() })
    }

    /// 指定クラスの待機者が `count` 件そろうまで待つ（sleep に頼らず決定的にする）。
    private func waitForWaiters(_ gate: MLInferenceGate,
                                interactive: Int = 0, background: Int = 0) async {
        while true {
            let state = await gate.debugState
            if state.interactive >= interactive && state.background >= background { return }
            await Task.yield()
        }
    }

    // MARK: - 優先度

    /// 保持中に background → interactive の順で並んでも、解放時は **interactive が先**に走る。
    func testInteractiveWaiterRunsBeforeBackground() async {
        let gate = MLInferenceGate()
        let recorder = Recorder()
        let holder = await startHolder(gate)

        let background = Task { await gate.run(priority: .background) { await recorder.add("bg") } }
        await waitForWaiters(gate, background: 1)      // 先に並んだことを確定させる

        let interactive = Task { await gate.run(priority: .interactive) { await recorder.add("ui") } }
        await waitForWaiters(gate, interactive: 1)

        holder.release()
        _ = await holder.task.value
        _ = await background.value
        _ = await interactive.value

        let order = await recorder.order
        XCTAssertEqual(order, ["ui", "bg"], "後から並んだ interactive が先に走るはず")
    }

    // MARK: - キャンセル

    /// 待機中にキャンセルされた待機者は、**自分のクラスの先頭**へ繰り上がる。
    func testCancelledWaiterIsPromotedWithinItsClass() async {
        let gate = MLInferenceGate()
        let recorder = Recorder()
        let holder = await startHolder(gate)

        let first = Task { await gate.run(priority: .background) { await recorder.add("first") } }
        await waitForWaiters(gate, background: 1)
        let second = Task { await gate.run(priority: .background) { await recorder.add("second") } }
        await waitForWaiters(gate, background: 2)
        let third = Task { await gate.run(priority: .background) { await recorder.add("third") } }
        await waitForWaiters(gate, background: 3)

        third.cancel()
        // 繰り上げは onCancel → actor へのホップ経由なので、反映を待つ（件数は変わらないため
        // 「先頭に来たか」は観測できない。十分に yield してから解放し、実行順で判定する）。
        for _ in 0..<200 { await Task.yield() }

        holder.release()
        _ = await holder.task.value
        _ = await first.value
        _ = await second.value
        _ = await third.value

        let order = await recorder.order
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order.first, "third", "キャンセルされた待機者が先頭へ繰り上がるはず")
        XCTAssertEqual(Set(order), ["first", "second", "third"], "取りこぼし・重複がないこと")
    }

    // MARK: - 内部状態の後始末（回帰テスト）

    /// 回帰テスト（本命）: **払い出し済みの ID に遅れて届いた promote** を `earlyCancels` に
    /// 記録しないこと。
    ///
    /// 修正前は `promote` が「どちらの列にも居ない＝まだ enqueue 前」と決めつけていたため、
    /// 払い出し済みの ID を `earlyCancels` に書き込んでいた。その ID は二度と enqueue されない
    /// ので削除されず、Set が**無制限に増え続ける**（スクロール中の先読み破棄で高頻度に起きる）。
    ///
    /// この競合はスケジューリング依存で決定的に再現できないため、seam 経由で契約を直接検証する。
    func testStalePromoteIsNotRecorded() async {
        let gate = MLInferenceGate()
        for id in 0..<100 {
            await gate.debugPromoteStaleWaiter(id)   // 待機していない ID への promote
        }
        let state = await gate.debugState
        XCTAssertEqual(state.earlyCancels, 0,
                       "払い出し済みの ID が earlyCancels に溜まっている（無制限増加のバグ）")
    }

    /// キャンセルを大量に浴びせても、処理後に待機列・`earlyCancels`・`pendingIDs` が空へ戻ること。
    ///
    /// これは不変条件のスモークテスト。競合の再現はスケジューラ任せなので、上の
    /// `testStalePromoteIsNotRecorded` が本命の回帰テストになる。
    func testInternalStateDrainsAfterCancellationStorm() async {
        let gate = MLInferenceGate()
        let holder = await startHolder(gate)

        var tasks: [Task<Void, Never>] = []
        for _ in 0..<40 {
            tasks.append(Task { await gate.run(priority: .background) { } })
        }
        await waitForWaiters(gate, background: 40)

        // 解放と同時にキャンセルを浴びせ、「払い出しと onCancel が競合する」状況を作る。
        holder.release()
        for task in tasks { task.cancel() }

        _ = await holder.task.value
        for task in tasks { _ = await task.value }

        let state = await gate.debugState
        XCTAssertEqual(state.interactive, 0)
        XCTAssertEqual(state.background, 0)
        XCTAssertEqual(state.pending, 0, "払い出し済みの ID が pendingIDs に残っている")
        XCTAssertEqual(state.earlyCancels, 0, "払い出し済みの ID が earlyCancels に残り続けている（無制限増加）")
        XCTAssertFalse(state.busy, "全員が抜けたらゲートは解放されているはず")
    }

    /// 全員が順番に通り、ゲートが最終的に解放されること（二重 resume / 取りこぼしがない）。
    func testAllWaitersRunExactlyOnceAndGateIsReleased() async {
        let gate = MLInferenceGate()
        let counter = Recorder()
        let holder = await startHolder(gate)

        var tasks: [Task<Void, Never>] = []
        for i in 0..<20 {
            tasks.append(Task { await gate.run { await counter.add("\(i)") } })
        }
        await waitForWaiters(gate, background: 20)

        holder.release()
        _ = await holder.task.value
        for task in tasks { _ = await task.value }

        let order = await counter.order
        XCTAssertEqual(order.count, 20, "全員がちょうど 1 回ずつ実行されるはず")
        XCTAssertEqual(Set(order).count, 20, "重複実行がないこと")
        let state = await gate.debugState
        XCTAssertFalse(state.busy)
    }

    // MARK: - 入れ子（安全網）

    /// `run` の中で `run` を呼んでもデッドロックせず、body が実行されること。
    /// （設計上は入れ子禁止だが、保険として素通しする。`assertionFailure` は Debug で止まるため
    ///   ここでは検証せず、**ハングしない**ことだけを確かめる。）
    func testNestedRunDoesNotDeadlockInRelease() async throws {
        #if DEBUG
        throw XCTSkip("入れ子は Debug では assertionFailure で停止するため、Release 相当でのみ検証する")
        #else
        let gate = MLInferenceGate()
        let value = await gate.run { await gate.run { 42 } }
        XCTAssertEqual(value, 42)
        #endif
    }
}
