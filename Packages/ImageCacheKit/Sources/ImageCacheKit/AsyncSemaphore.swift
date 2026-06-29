import Foundation

/// async/await 向けの計数セマフォ。CPU 負荷の高い処理（画像デコード等）の**同時実行数を制限**して
/// 協調スレッドプールの飽和を防ぐ。要求ごとに無制限の `Task.detached` を生むと、スレッドが過多になり
/// CPU 競合で 1 件あたりの処理が桁違いに遅くなる（実機でサムネのディスクデコードが ~129ms に膨張）。
///
/// 使い方: `await sem.acquire()` で許可を取り、処理後に `await sem.release()` で返す。
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) { available = max(0, value) }

    /// 許可が空くまで待つ。
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 許可を返す（待機者がいれば 1 人起こす）。
    public func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
