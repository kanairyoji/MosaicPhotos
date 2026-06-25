#if canImport(UIKit)
import SwiftUI
import QuartzCore

/// スクロール速度を監視し、**速い間だけ** active=true を通知するモディファイア（R3）。
/// 高速スクロール中はサムネ取得・先読み・背景処理を止めて画面操作を最優先にするために使う。
/// `onScrollGeometryChange` は iOS 18+ のため、未満では何もしない（R1 の出現遅延でも十分機能する）。
@available(iOS 18.0, *)
private struct ScrollVelocityPauseModifier: ViewModifier {
    let onActiveChange: (Bool) -> Void

    @State private var lastOffset: CGFloat = 0
    @State private var lastTime: CFTimeInterval = 0
    @State private var active = false
    @State private var settleTask: Task<Void, Never>?

    /// これを超える速度（pt/秒）で「高速スクロール中」とみなす。
    private let speedThreshold: CGFloat = 2200

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, newY in
            let now = CACurrentMediaTime()
            let dt = now - lastTime
            if lastTime != 0, dt > 0 {
                let speed = abs(newY - lastOffset) / CGFloat(dt)
                if speed > speedThreshold {
                    if !active { active = true; onActiveChange(true) }
                    scheduleSettle()
                }
            }
            lastOffset = newY
            lastTime = now
        }
    }

    /// 一定時間（~140ms）高速イベントが来なければ「落ち着いた」とみなして解除する。
    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            active = false
            onActiveChange(false)
        }
    }
}

extension View {
    /// 高速スクロール中だけ `onActiveChange(true)`、落ち着いたら `false` を通知する。
    @ViewBuilder
    func pauseOnFastScroll(_ onActiveChange: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            modifier(ScrollVelocityPauseModifier(onActiveChange: onActiveChange))
        } else {
            self
        }
    }
}
#endif
