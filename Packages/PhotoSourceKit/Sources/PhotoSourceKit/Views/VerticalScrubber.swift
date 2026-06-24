#if canImport(UIKit)
import SwiftUI

/// グリッド右端に出す縦スクロール用スクラバー。ハンドルを上下にドラッグすると、
/// その位置（0…1）に応じて一覧を素早くスクロールする（大量の写真の高速移動用）。
/// 実際のスクロールは呼び出し側が `onScrub(fraction)` で `ScrollViewProxy.scrollTo` を行う。
struct VerticalScrubber: View {
    /// ドラッグ位置（0=先頭 … 1=末尾）を通知する。
    let onScrub: (Double) -> Void

    /// ハンドル位置（0…1）。末尾アンカー（タイムラインは下端が最新）に合わせ既定は 1。
    @State private var fraction: Double = 1
    @GestureState private var dragging = false

    private let handleHeight: CGFloat = 50
    private let handleWidth: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.height - handleHeight)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: handleWidth, height: handleHeight)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
                .shadow(radius: dragging ? 5 : 1)
                .scaleEffect(dragging ? 1.1 : 1)
                .offset(y: CGFloat(min(max(0, fraction), 1)) * usable)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragging) { _, state, _ in state = true }
                        .onChanged { value in
                            let f = Double((value.location.y - handleHeight / 2) / usable)
                            fraction = min(max(0, f), 1)
                            onScrub(fraction)
                        }
                )
                .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(width: 40)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
    }
}
#endif
