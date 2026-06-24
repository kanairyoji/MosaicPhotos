#if canImport(UIKit)
import SwiftUI

/// Transparent background view that walks up the UIKit superview chain to the
/// backing UIScrollView and attaches a UIPinchGestureRecognizer directly to it.
///
/// SwiftUI's MagnificationGesture placed on (or inside) a ScrollView is silently
/// consumed by UIScrollView's internal gesture handling, so this UIKit-level
/// bridge is required to receive pinch events reliably.
struct PinchRecognizerBridge: UIViewRepresentable {
    let onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnded: onEnded) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false   // invisible to touches; recognizer lives on UIScrollView
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onEnded = onEnded
        guard !context.coordinator.didAttach else { return }
        // Defer one run-loop cycle so the superview chain is fully built.
        DispatchQueue.main.async {
            guard !context.coordinator.didAttach,
                  uiView.window != nil,
                  let scrollView = uiView.nearestAncestorScrollView() else {
                return
            }
            let r = UIPinchGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handle(_:))
            )
            r.cancelsTouchesInView = false  // don't block NavigationLink taps or scroll
            r.delegate = context.coordinator
            scrollView.addGestureRecognizer(r)
            context.coordinator.didAttach = true
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEnded: (CGFloat) -> Void
        var didAttach = false

        init(onEnded: @escaping (CGFloat) -> Void) { self.onEnded = onEnded }

        @objc func handle(_ r: UIPinchGestureRecognizer) {
            guard r.state == .ended else { return }
            onEnded(r.scale)
        }

        // Allow the pinch recognizer to fire alongside the scroll pan recognizer.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}

// MARK: - UIView helper

private extension UIView {
    func nearestAncestorScrollView() -> UIScrollView? {
        var current: UIView? = superview
        while let view = current {
            if let scroll = view as? UIScrollView { return scroll }
            current = view.superview
        }
        return nil
    }
}
#endif
