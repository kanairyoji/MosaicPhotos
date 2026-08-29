import SwiftUI

/// **キャンセルできる重い読み込み**（ADR-124 の作法をコードで固定する）。
///
/// ⚠️ 同じ形を 3 画面（人物レビュー / まとめて確認 / 地図）で手書きしていた。書くたびに次の 3 つを
/// 思い出す必要がある——(1) **表示を確定させてから**処理を始める（さもないと「何も出ないまま
/// 待たされる」）、(2) 走っている Task を保持する（でないと中断できない）、(3) キャンセルされた
/// 結果は**反映しない**（戻ったときに古い結果で上書きしない）。1 つ忘れるとそのぶん体感が悪くなる。
///
/// - Parameters:
///   - isBusy: スピナー表示のフラグ（`busyOverlay` に渡しているもの）。
///   - task: 実行中の Task を保持する `@State`（キャンセルボタンから触るため呼び出し側が持つ）。
/// - Returns: 結果。**キャンセルされたときは nil**（呼び出し側は何も反映しない）。
@MainActor
public func runCancellable<T>(isBusy: Binding<Bool>,
                              task holder: Binding<Task<T, Never>?>,
                              settleFrames: Int = 2,
                              _ work: @escaping @MainActor () async -> T) async -> T? {
    holder.wrappedValue?.cancel()
    let task = Task { @MainActor in await work() }
    holder.wrappedValue = task
    isBusy.wrappedValue = true
    for _ in 0..<max(0, settleFrames) {
        try? await Task.sleep(nanoseconds: 16_666_667)   // 1 フレーム（60fps 相当）
    }
    let value = await task.value
    guard !task.isCancelled else { return nil }
    // ⚠️ 自分が現行のときだけ後始末する（待っている間に次の実行が始まっていることがある）。
    if holder.wrappedValue == task {
        holder.wrappedValue = nil
        isBusy.wrappedValue = false
    }
    return value
}

/// 実行中の読み込みを中断する（キャンセルボタン・画面を閉じるとき）。
@MainActor
public func cancelRunning<T>(isBusy: Binding<Bool>, task holder: Binding<Task<T, Never>?>) {
    holder.wrappedValue?.cancel()
    holder.wrappedValue = nil
    isBusy.wrappedValue = false
}
