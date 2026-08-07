import CoreGraphics
import Testing
@testable import PhotoSourceKit

/// ズーム表示の数値計算（フィットサイズ・最大倍率・中央寄せ）を検証する。
@Suite("ZoomMath")
struct ZoomMathTests {

    @Test("横長画像は幅フィット・縦長画像は高さフィット")
    func fittedSizeAspect() {
        let container = CGSize(width: 400, height: 800)
        // 横長 4000x2000 → 幅 400 に合わせて 400x200。
        let landscape = ZoomMath.fittedSize(imagePixel: CGSize(width: 4000, height: 2000), container: container)
        #expect(landscape == CGSize(width: 400, height: 200))
        // 縦長 2000x8000 → 高さ 800 に合わせて 200x800。
        let portrait = ZoomMath.fittedSize(imagePixel: CGSize(width: 2000, height: 8000), container: container)
        #expect(portrait == CGSize(width: 200, height: 800))
    }

    @Test("不正入力（ゼロ・負）は .zero")
    func fittedSizeInvalid() {
        #expect(ZoomMath.fittedSize(imagePixel: .zero, container: CGSize(width: 400, height: 800)) == .zero)
        #expect(ZoomMath.fittedSize(imagePixel: CGSize(width: 100, height: 100), container: .zero) == .zero)
    }

    @Test("最大倍率＝画像ピクセル 1:1（最低 3x 保証）")
    func maxZoom() {
        // 4000px を 400pt（@3x=1200px）で表示 → 1:1 は 3.33x。
        let high = ZoomMath.maxZoomScale(imagePixelWidth: 4000, fittedWidth: 400, displayScale: 3)
        #expect(abs(high - 4000.0 / 1200.0) < 0.001)
        // 低解像度（1:1 が 3x 未満）でも 3x は保証する。
        let low = ZoomMath.maxZoomScale(imagePixelWidth: 800, fittedWidth: 400, displayScale: 3)
        #expect(low == 3)
        // 不正入力は既定の 3x。
        #expect(ZoomMath.maxZoomScale(imagePixelWidth: 0, fittedWidth: 400, displayScale: 3) == 3)
    }

    @Test("中央寄せインセットは片側（容器-コンテンツ）/2・はみ出しは 0")
    func centeringInset() {
        #expect(ZoomMath.centeringInset(container: 800, content: 200) == 300)
        #expect(ZoomMath.centeringInset(container: 400, content: 400) == 0)
        #expect(ZoomMath.centeringInset(container: 400, content: 900) == 0)   // 拡大ではみ出し
    }
}
