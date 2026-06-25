#if canImport(UIKit)
import SwiftUI

/// グリッド右端に出す縦スクロール用スクラバー。ハンドルを上下にドラッグすると、
/// その位置（0…1）に応じて一覧を素早くスクロールする（大量の写真の高速移動用）。
/// 実際のスクロールは呼び出し側が `onScrub(fraction)` で `ScrollViewProxy.scrollTo` を行う。
///
/// ⚠️ パフォーマンス：ハンドル追従（`fraction`）はドラッグの毎デルタで即時更新して指に張り付かせる一方、
/// `onScrub`（= 重い `scrollTo` を伴う）は **~30fps に合体スロットリング**する。毎デルタで `scrollTo` すると
/// 数万件規模のグリッドでレイアウト・セル実体化・サムネ先読みが殺到してハンドルもスクロールも固まるため。
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

    // スロットリング用：最新の保留位置と、トレーリング発火が予約済みかのフラグ。
    @State private var pendingFraction: Double?
    @State private var emitScheduled = false

    private let handleHeight: CGFloat = 50
    private let handleWidth: CGFloat = 34
    private let emitInterval: Duration = .milliseconds(33)   // ~30fps

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
                            fraction = min(max(0, f), 1)   // ハンドルは即時追従（軽い）
                            scheduleScrub(fraction)        // scrollTo は合体スロットリング
                        }
                        .onEnded { _ in
                            // ドラッグ終了時は最終位置へ確実にスクロールし、操作終了を通知する。
                            onScrub(fraction)
                            pendingFraction = nil
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

    /// 最新位置を保留し、~30fps で1回だけ `onScrub` を発火する（連続デルタを1回に合体）。
    private func scheduleScrub(_ f: Double) {
        pendingFraction = f
        guard !emitScheduled else { return }
        emitScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: emitInterval)
            emitScheduled = false
            if let pending = pendingFraction {
                pendingFraction = nil
                onScrub(pending)
            }
        }
    }
}
#endif
