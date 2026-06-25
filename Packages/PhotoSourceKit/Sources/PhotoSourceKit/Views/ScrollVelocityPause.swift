#if canImport(UIKit)
import SwiftUI
import QuartzCore

/// スクロール速度を監視し、**速い間だけ** active=true を通知するモディファイア（R3）。
/// 高速スクロール中はサムネ取得・先読み・背景処理を止めて画面操作を最優先にするために使う。
/// `onScrollGeometryChange` は iOS 18+ のため、未満では何もしない（R1 の出現遅延でも十分機能する）。
@available(iOS 18.0, *)
private struct ScrollVelocityPauseModifier: ViewModifier {
    /// false の間は監視・通知を行わない（スクラバーのプログラム的 scrollTo と競合させないため）。
    let enabled: Bool
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
            // スクラブ中など無効時は何もしない。基準だけ更新して誤検出を防ぐ。
            guard enabled else { lastOffset = newY; lastTime = CACurrentMediaTime(); return }
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
    /// `enabled: false`（例：スクラブ中）の間は監視・通知しない。
    @ViewBuilder
    func pauseOnFastScroll(enabled: Bool = true, _ onActiveChange: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, *) {
            modifier(ScrollVelocityPauseModifier(enabled: enabled, onActiveChange: onActiveChange))
        } else {
            self
        }
    }
}
#endif
