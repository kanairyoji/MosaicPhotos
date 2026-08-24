import Foundation

/// 「完了通知は一度だけ」を保証するラッチ（純ロジック・テスト対象）。
///
/// ⚠️ `BGTask.setTaskCompleted(success:)` は**1 回しか呼べない**（二重に呼ぶと
/// BGTaskScheduler が例外を投げる）。期限切れハンドラと本体の終了処理はどちらも
/// 「終わった」と判断し得るので、通知は必ずここを通して 1 回に絞る（レビュー指摘）。
///
/// `@MainActor` 前提（BGTask のハンドラはメインで扱う）。
@MainActor
public final class CompletionLatch {
    private var didComplete = false

    public init() {}

    /// まだ通知していなければ `body` を実行して true を返す。2 回目以降は false（何もしない）。
    @discardableResult
    public func completeOnce(_ body: () -> Void) -> Bool {
        guard !didComplete else { return false }
        didComplete = true
        body()
        return true
    }

    /// 次の実行のために戻す（BGTask 1 回分ごとに使い回すため）。
    public func reset() { didComplete = false }

    public var hasCompleted: Bool { didComplete }
}
