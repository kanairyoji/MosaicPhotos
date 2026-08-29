import SwiftUI
import Testing
@testable import PhotoSourceKit

/// キャンセルできる重い読み込み（ADR-124）。
///
/// ⚠️ ここが守っているのは 3 点: 表示フラグが立つ／中断した回は**結果を返さない**／
/// 中断したら実行中フラグが下りる。3 画面で手書きしていたときは、どれかを忘れると
/// 「押しても閉じない」「戻ったら古い結果が出る」という形で表に出ていた。
@Suite("キャンセルできる読み込み")
@MainActor
struct CancellableWorkTests {

    /// Binding の実体を持つ小さな箱（SwiftUI 無しで `Binding` を作る）。
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
        var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }

    @Test("完了したら結果を返し、実行中フラグを下ろす")
    func completesAndClears() async {
        let busy = Box(false), task = Box<Task<Int, Never>?>(nil)
        let value = await runCancellable(isBusy: busy.binding, task: task.binding,
                                         settleFrames: 0) { 42 }
        #expect(value == 42)
        #expect(busy.value == false, "実行中フラグが下りていない")
        #expect(task.value == nil, "Task を持ったままになっている")
    }

    @Test("中断した回は結果を返さない（古い結果で上書きしない）")
    func cancelledReturnsNil() async {
        let busy = Box(false), task = Box<Task<Int, Never>?>(nil)
        async let running: Int? = runCancellable(isBusy: busy.binding, task: task.binding,
                                                 settleFrames: 0) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return 7
        }
        // 走り出してから中断する。
        try? await Task.sleep(nanoseconds: 20_000_000)
        cancelRunning(isBusy: busy.binding, task: task.binding)
        let value = await running
        #expect(value == nil, "中断したのに結果を返した")
        #expect(busy.value == false)
    }

    @Test("次の実行は前の実行を中断して置き換える")
    func newRunReplacesPrevious() async {
        let busy = Box(false), task = Box<Task<String, Never>?>(nil)
        async let first: String? = runCancellable(isBusy: busy.binding, task: task.binding,
                                                  settleFrames: 0) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            return "old"
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = await runCancellable(isBusy: busy.binding, task: task.binding,
                                          settleFrames: 0) { "new" }
        #expect(second == "new")
        #expect(await first == nil, "前の実行の結果が返っている（新しい表示を壊す）")
    }
}
