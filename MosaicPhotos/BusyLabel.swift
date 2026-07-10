import SwiftUI

// MARK: - Busy label（実行ボタン共通のスピナー付きラベル）

/// 「実行中はスピナー＋進行中の文言、通常時は普通のラベル」を出すボタンラベル。
/// 設定各画面の実行ボタン（Clear / Generate / Re-analyze …）で同じ
/// `HStack { ProgressView(); Text }` パターンが繰り返されていたため 1 つに集約する。
struct BusyLabel: View {
    private let idle: Text
    private let busy: Text
    private let isBusy: Bool

    /// 通常時・実行中とも固定文言で足りる場合（もっとも一般的）。
    init(_ idle: LocalizedStringKey, busy: LocalizedStringKey, isBusy: Bool) {
        self.init(idle: Text(idle), busy: Text(busy), isBusy: isBusy)
    }

    /// 実行中も同じ文言のままスピナーだけ添える場合。
    init(_ title: LocalizedStringKey, isBusy: Bool) {
        self.init(idle: Text(title), busy: Text(title), isBusy: isBusy)
    }

    /// 動的な文言（`L(...)` 済みの String など）を渡す場合は `Text` を直接指定する。
    init(idle: Text, busy: Text, isBusy: Bool) {
        self.idle = idle
        self.busy = busy
        self.isBusy = isBusy
    }

    var body: some View {
        if isBusy {
            HStack { ProgressView().controlSize(.small); busy }
        } else {
            idle
        }
    }
}
