import Foundation

/// 「完了通知は一度だけ」を保証するラッチ（純ロジック・テスト対象）。
///
/// ⚠️ `BGTask.setTaskCompleted(success:)` は**1 回しか呼べない**（二重に呼ぶと
/// BGTaskScheduler が例外を投げる）。期限切れハンドラと本体の終了処理はどちらも
/// 「終わった」と判断し得るので、通知は必ずここを通して 1 回に絞る。
///
/// ⚠️ **世代を持つのが要点**（レビュー指摘）。BGTask ごとに使い回すため、単なる真偽値では
/// 前後の実行を区別できない。実際の順序として、
///   A の期限切れが完了通知 → A 本体はキャンセル済みだがまだ終了待ち
///   → B が始まって新しい世代を開始 → **その後で A 本体が完了通知に来る**
/// が起こり得る。世代が無いと、この A の通知が通ってしまい（＝A が二重に
/// `setTaskCompleted` を呼ぶ）、さらにラッチが消費済みになって **B の正規の完了通知が
/// 黙って捨てられる**（B は OS へ完了を伝えられない）。
///
/// `@MainActor` 前提（BGTask のハンドラはメインで扱う）。
@MainActor
public final class CompletionLatch {
    private var generation = 0
    /// 完了通知を出した世代（nil＝現世代はまだ未通知）。
    private var completedGeneration: Int?

    public init() {}

    /// 新しい実行を開始し、その**世代トークン**を返す。以後の通知はこれを添えて行う。
    public func begin() -> Int {
        generation &+= 1
        return generation
    }

    /// 現世代の通知としてまだ出していなければ `body` を実行して true を返す。
    /// 2 回目以降、および**古い世代からの通知**は false（何もしない）。
    @discardableResult
    public func completeOnce(_ token: Int, _ body: () -> Void) -> Bool {
        guard token == generation else { return false }        // 旧世代の遅れた通知
        guard completedGeneration != token else { return false } // 同一世代の二重通知
        completedGeneration = token
        body()
        return true
    }

    /// 現世代が通知済みか。
    public var hasCompleted: Bool { completedGeneration == generation }
}
