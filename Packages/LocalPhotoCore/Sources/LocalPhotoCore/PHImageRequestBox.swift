import Foundation
import Photos

/// PhotoKit の要求 ID とキャンセル要求を**ロックで対に**扱う箱。
///
/// ⚠️ `requestImage` が ID を返す前にキャンセルハンドラが走ると、ID はまだ無効値のままで
/// `cancelImageRequest` は何も取り消せない。その後に要求が登録されるため、
/// **画面外になったサムネイル取得が最後まで走り続ける**（高速スクロールで大量に残る・
/// レビュー指摘）。登録時に「既にキャンセル済みか」を返し、その場で取り消せるようにする。
final class PHImageRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID = PHInvalidImageRequestID
    private var isCancelled = false
    private var isFinished = false
    /// degraded を最初に見せた時刻（ns・0=未表示）。firstMs 計測用。
    var degradedShownNs: UInt64 = 0

    /// 要求 ID を登録する。**既にキャンセル済みなら true**（呼び出し側がその場で取り消す）。
    func register(_ newID: PHImageRequestID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        id = newID
        return isCancelled
    }

    /// キャンセルを記録し、取り消すべき ID があれば返す（未登録なら nil）。
    func cancel() -> PHImageRequestID? {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        return id == PHInvalidImageRequestID ? nil : id
    }

    /// 完了を 1 回だけ通す（PhotoKit は degraded → final と複数回呼ぶ）。
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isFinished { return false }
        isFinished = true
        return true
    }

    var finished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }
}
