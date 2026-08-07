import CoreGraphics
import Foundation

/// ズーム表示の数値計算（純・テスト対象）。UIKit 非依存なので macOS でテストできる。
public enum ZoomMath {
    /// 画像（ピクセル）を容器（ポイント）へアスペクトフィットしたサイズ（ポイント）。
    public static func fittedSize(imagePixel: CGSize, container: CGSize) -> CGSize {
        guard imagePixel.width > 0, imagePixel.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imagePixel.width, container.height / imagePixel.height)
        return CGSize(width: imagePixel.width * scale, height: imagePixel.height * scale)
    }

    /// 最大ズーム倍率＝「画像ピクセル＝画面ピクセル（1:1）」になる倍率（最低 3x 保証）。
    /// 高解像度写真ほど深くズームでき、それ以上はボケるだけなので止める。
    public static func maxZoomScale(imagePixelWidth: CGFloat, fittedWidth: CGFloat,
                                    displayScale: CGFloat) -> CGFloat {
        guard imagePixelWidth > 0, fittedWidth > 0, displayScale > 0 else { return 3 }
        return max(3, imagePixelWidth / (fittedWidth * displayScale))
    }

    /// コンテンツが容器より小さい辺を中央寄せするための片側インセット。
    public static func centeringInset(container: CGFloat, content: CGFloat) -> CGFloat {
        max(0, (container - content) / 2)
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

/// ピンチ拡大・パン・ダブルタップ切替を **UIScrollView のネイティブ挙動**で提供するズームコンテナ。
///
/// ジェスチャーの調停（設計の核心・ADR-77）:
/// - **1x のときはパンを消費しない**（contentSize ≦ bounds かつ alwaysBounce=false で pan が不成立）。
///   → 外側の TabView ページング・縦スクロール（情報パネル）・下引っ張り閉じが従来どおり動く。
/// - **拡大中はパンを消費する**（端はラバーバンド）→ 誤ページ送り・誤クローズを防ぐ。
///   ズーム状態は `onZoomChanged` で親へ報告し、親は縦スクロールを止める。
/// - シングルタップはダブルタップの失敗待ち（約0.3s）で `onSingleTap`（バー表示切替用）。
/// - ダブルタップ: 1x ⇄ 2.5x（タップ位置中心）。ピンチで 1x 未満に離すと 1x へスプリング
///   （bouncesZoom＝UIScrollView 標準）。
struct ZoomableImageView<Content: View>: UIViewRepresentable {
    /// 表示領域（ページのフルサイズ・ポイント）。
    let containerSize: CGSize
    /// 元画像のピクセルサイズ（フィットサイズ・最大倍率の計算用）。
    let imagePixelSize: CGSize
    /// インクリメントするとズームを 1x へ戻す（ページが画面外へ出たときに親が上げる）。
    let resetToken: Int
    let onZoomChanged: (Bool) -> Void
    let onSingleTap: () -> Void
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1   // applyLayout で画像に応じて設定
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        // 1x でパンを不成立にする要（contentSize ≦ bounds なら外側へ透過）。
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []   // 安全領域をコンテンツへ伝播させない（レイアウトずれ防止）
        scrollView.addSubview(host.view)
        context.coordinator.hosting = host
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onZoomChanged = onZoomChanged
        coordinator.onSingleTap = onSingleTap
        coordinator.hosting?.rootView = content()

        // 容器サイズ・画像が変わったらフィットし直す（ズームは 1x へ）。
        if coordinator.lastContainer != containerSize || coordinator.lastImagePixel != imagePixelSize {
            coordinator.lastContainer = containerSize
            coordinator.lastImagePixel = imagePixelSize
            coordinator.applyLayout()
        }
        if coordinator.lastResetToken != resetToken {
            coordinator.lastResetToken = resetToken
            if scrollView.zoomScale > 1.001 { scrollView.setZoomScale(1, animated: false) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        var hosting: UIHostingController<Content>?
        var onZoomChanged: ((Bool) -> Void)?
        var onSingleTap: (() -> Void)?
        var lastContainer: CGSize = .zero
        var lastImagePixel: CGSize = .zero
        var lastResetToken = Int.min
        private var lastReportedZoomed = false

        /// ダブルタップの拡大先（Apple 写真と同程度）。※ ジェネリック型内のため stored static 不可。
        private static var doubleTapScale: CGFloat { 2.5 }

        func applyLayout() {
            guard let scrollView, let host = hosting else { return }
            let fitted = ZoomMath.fittedSize(imagePixel: lastImagePixel, container: lastContainer)
            guard fitted != .zero else { return }
            scrollView.zoomScale = 1
            host.view.frame = CGRect(origin: .zero, size: fitted)
            scrollView.contentSize = fitted
            let displayScale = max(1, scrollView.traitCollection.displayScale)
            scrollView.maximumZoomScale = ZoomMath.maxZoomScale(
                imagePixelWidth: lastImagePixel.width, fittedWidth: fitted.width,
                displayScale: displayScale)
            centerContent()
            reportZoomState()
        }

        /// コンテンツが容器より小さい辺を中央へ寄せる（レターボックス分をインセットで埋める）。
        private func centerContent() {
            guard let scrollView else { return }
            let insetX = ZoomMath.centeringInset(container: lastContainer.width,
                                                 content: scrollView.contentSize.width)
            let insetY = ZoomMath.centeringInset(container: lastContainer.height,
                                                 content: scrollView.contentSize.height)
            scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        }

        /// ズーム中かどうかを（値が変わったときだけ）親へ通知する。SwiftUI の update 中に
        /// 状態を書き換えないよう次のランループへ逃がす。
        private func reportZoomState() {
            guard let scrollView else { return }
            let zoomed = scrollView.zoomScale > 1.01
            guard zoomed != lastReportedZoomed else { return }
            lastReportedZoomed = zoomed
            let callback = onZoomChanged
            DispatchQueue.main.async { callback?(zoomed) }
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { hosting?.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent()
            reportZoomState()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportZoomState()
        }

        // MARK: - Gestures

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let host = hosting else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let target = min(Self.doubleTapScale, scrollView.maximumZoomScale)
                let point = gesture.location(in: host.view)
                let size = CGSize(width: scrollView.bounds.width / target,
                                  height: scrollView.bounds.height / target)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }

        @objc func handleSingleTap() {
            onSingleTap?()
        }
    }
}
#endif
