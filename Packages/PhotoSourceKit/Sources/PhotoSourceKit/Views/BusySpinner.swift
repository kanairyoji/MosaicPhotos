#if canImport(UIKit)
import Observation
import SwiftUI
import UIKit

/// メインスレッドが止まっている間も**回り続ける**スピナー（ユーザー要望・ADR-96）。
///
/// ⚠️ ここが肝: `UIActivityIndicatorView` の回転は `CAAnimation` で、いったんレンダーサーバへ
/// コミットされると**別プロセス側で進む**。したがってメインスレッドがブロックされても回転は
/// 止まらない＝「アプリが死んだ」ではなく「処理中」だとユーザーに伝わる。
/// SwiftUI 標準の `ProgressView` はフレーム駆動になり得る（メインが止まると一緒に止まる）ため、
/// **止まっている間こそ見せたい**箇所ではこちらを使う。
///
/// ⚠️ 限界（重要）: スピナーは**ブロックが始まる前に画面へ出ている**必要がある。表示が確定する
/// 前にメインが止まれば、何も描かれないまま固まる——「固まっているから出せない」は、この意味で
/// 半分正しい。だから重い処理の前に出す場合は `busyOverlay` ではなく
/// `runShowingBusy(...)` を使い、**1〜2 フレーム譲ってから**処理を始めること。
public struct BusySpinner: UIViewRepresentable {
    public var style: UIActivityIndicatorView.Style
    public var tint: UIColor?

    public init(style: UIActivityIndicatorView.Style = .medium, tint: UIColor? = nil) {
        self.style = style
        self.tint = tint
    }

    public func makeUIView(context: Context) -> UIActivityIndicatorView {
        let view = UIActivityIndicatorView(style: style)
        view.tintColor = tint
        view.color = tint
        view.hidesWhenStopped = true
        view.startAnimating()
        return view
    }

    public func updateUIView(_ view: UIActivityIndicatorView, context: Context) {
        view.color = tint
        // 再利用時に停止していたら回し直す（オーバーレイの出し入れで止まったままにしない）。
        if !view.isAnimating { view.startAnimating() }
    }
}

public extension View {
    /// 「考え中」オーバーレイ。`isBusy` の間、レンダーサーバ駆動のスピナーを重ねる。
    /// 既に非同期で待っている箇所（読み込み中など）に付ける。
    ///
    /// - Parameter cancel: 中断できる処理なら `(ラベル, 実行)` を渡す。**数秒かかり得る待ちには
    ///   必ず付ける**（実フィードバック: 「探している間、何も操作できない」）。待たされている側に
    ///   出口が無いのは、遅いこと自体より応える。
    func busyOverlay(_ isBusy: Bool, text: String? = nil,
                     cancel: (label: String, action: () -> Void)? = nil) -> some View {
        overlay {
            if isBusy {
                VStack(spacing: 10) {
                    BusySpinner(style: .large)
                    if let text {
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let cancel {
                        Button(cancel.label, action: cancel.action)
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(Text(text ?? "Working"))
            }
        }
    }
}

/// 重い処理を「考え中」表示付きで走らせる。
///
/// ⚠️ **表示を確定させてから**処理を始めるのが肝。フラグを立てた直後に重い処理へ入ると、
/// SwiftUI が描画する前にメインを掴んでしまい「何も出ないまま固まる」になる。ここで
/// 数フレーム譲ることで、以後メインがブロックされてもスピナーは回り続ける（CAAnimation）。
/// - Parameter settleFrames: 表示確定のために譲るフレーム数（既定 2＝約 33ms）。
@MainActor
public func runShowingBusy<T>(_ isBusy: Binding<Bool>,
                              settleFrames: Int = 2,
                              _ work: @MainActor () async -> T) async -> T {
    isBusy.wrappedValue = true
    for _ in 0..<max(0, settleFrames) {
        try? await Task.sleep(nanoseconds: 16_666_667)   // 1 フレーム（60fps 相当）
    }
    let result = await work()
    isBusy.wrappedValue = false
    return result
}
#endif
