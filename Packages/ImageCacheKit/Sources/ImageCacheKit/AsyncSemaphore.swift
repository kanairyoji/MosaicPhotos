import Foundation

/// async/await 向けの計数セマフォ。CPU 負荷の高い処理（画像デコード等）の**同時実行数を制限**して
/// 協調スレッドプールの飽和を防ぐ。要求ごとに無制限の `Task.detached` を生むと、スレッドが過多になり
/// CPU 競合で 1 件あたりの処理が桁違いに遅くなる（実機でサムネのディスクデコードが ~129ms に膨張）。
///
/// 使い方: `await sem.acquire()` で許可を取り、処理後に `await sem.release()` で返す。
///
/// キャンセル: 待機中にタスクがキャンセルされたら、その待機者を**列の先頭へ繰り上げる**（ADR-75）。
/// `acquire` は必ず成功する契約（＝呼び出し側の `release` と 1:1 で対応する）を保ちたいので、
/// 待たずに抜けさせるのではなく待ち時間を最短化する。これで「スクロールで破棄されたデコード要求が
/// 行列の最後尾で順番待ちし、キャンセル済みなのに残り続ける」状態を避けられる。
public actor AsyncSemaphore {
    private struct Waiter {
        let id: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    /// enqueue より先にキャンセルが届いた待機者の ID。
    private var earlyCancels: Set<Int> = []

    public init(value: Int) { available = max(0, value) }

    /// 許可が空くまで待つ。
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        let id = nextWaiterID
        nextWaiterID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                enqueue(Waiter(id: id, continuation: cont))
            }
        } onCancel: {
            Task { await self.promote(id) }
        }
    }

    /// 許可を返す（待機者がいれば 1 人起こす）。
    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func enqueue(_ waiter: Waiter) {
        if earlyCancels.remove(waiter.id) != nil { waiters.insert(waiter, at: 0) }
        else { waiters.append(waiter) }
    }

    private func promote(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            earlyCancels.insert(id)   // enqueue 前にキャンセルが届いた
            return
        }
        guard index > 0 else { return }
        let waiter = waiters.remove(at: index)
        waiters.insert(waiter, at: 0)
    }
}
