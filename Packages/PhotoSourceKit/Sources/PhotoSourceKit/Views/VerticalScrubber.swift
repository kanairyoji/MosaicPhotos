#if canImport(UIKit)
import SwiftUI

/// グリッド右端に出す縦スクロール用スクラバー。ハンドルを上下にドラッグすると、
/// その位置（0…1）に応じて一覧を素早くスクロールする（大量の写真の高速移動用）。
/// 実際のスクロールは呼び出し側が `onScrub(fraction)` で `ScrollViewProxy.scrollTo` を行う。
///
/// スクラブ中はサムネ取得・先読みを止めている（`onActiveChange`）ため `scrollTo` は軽い。
/// よって**ドラッグの毎デルタで即時スクロール**し、ハンドルと画面が指にぴったり追従するようにする。
struct VerticalScrubber: View {
    /// ドラッグ位置（0=先頭 … 1=末尾）を通知する。
    let onScrub: (Double) -> Void
    /// ドラッグの開始（true）／終了（false）を通知する。スクラブ中はサムネ取得・先読み・
    /// 背景処理を止めて操作を滑らかにするために使う。
    var onActiveChange: ((Bool) -> Void)?

    /// ハンドル位置（0…1）。末尾アンカー（タイムラインは下端が最新）に合わせ既定は 1。
    @State private var fraction: Double = 1
    @State private var active = false
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
                            if !active { active = true; onActiveChange?(true) }   // ドラッグ開始
                            let f = Double((value.location.y - handleHeight / 2) / usable)
                            fraction = min(max(0, f), 1)
                            onScrub(fraction)   // 即時スクロール（スクラブ中は画像取得を止めているため軽い）
                        }
                        .onEnded { _ in
                            onScrub(fraction)
                            active = false
                            onActiveChange?(false)
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
