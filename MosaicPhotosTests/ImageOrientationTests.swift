import MosaicSupport
import UIKit
import XCTest

/// 画像の向き正規化ロジック（`PHAssetImageLoader`）の回帰テスト。
///
/// 背景: グリッドサムネが 90° 横倒しになる不具合（真因＝小さい targetSize で PHImageManager が
/// 向きの狂ったサムネを返す）を修正した。PHImageManager の挙動そのものはユニットテストで再現できないが、
/// 修正の**核となる純ロジック**——「向きを .up へ焼き込む」「縮小しても見た目を保つ」「取得サイズを
/// 640 下限へ引き上げる」——はここで決定的に守れる。
///
/// 手法: 四象限に別々の色（左上=赤/右上=緑/左下=青/右下=黄）を塗った**非対称マーカー画像**を作り、
/// 「向きを尊重してレンダリングした四隅の色」を**オラクル**として比較する。向きが崩れれば四隅の
/// 並びが変わるので検出できる。
final class ImageOrientationTests: XCTestCase {

    // MARK: - オラクル（四隅の色）

    private enum Corner: String { case red, green, blue, yellow, other }

    /// 非対称マーカー画像（.up）。四象限に赤/緑/青/黄。
    private func markerImage(width: CGFloat, height: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: fmt).image { ctx in
            let c = ctx.cgContext
            let w = width / 2, h = height / 2
            c.setFillColor(UIColor.red.cgColor);    c.fill(CGRect(x: 0, y: 0, width: w, height: h))      // 左上
            c.setFillColor(UIColor.green.cgColor);  c.fill(CGRect(x: w, y: 0, width: w, height: h))      // 右上
            c.setFillColor(UIColor.blue.cgColor);   c.fill(CGRect(x: 0, y: h, width: w, height: h))      // 左下
            c.setFillColor(UIColor.yellow.cgColor); c.fill(CGRect(x: w, y: h, width: w, height: h))      // 右下
        }
    }

    /// 画像を**向きを尊重して**レンダリングし、四象限の中心色を返す（[左上,右上,左下,右下]）。
    private func cornerColors(_ image: UIImage) -> [Corner] {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let cg = UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage!
        let w = cg.width, h = cg.height
        // 各象限の中心を読む。
        let points = [(w / 4, h / 4), (3 * w / 4, h / 4), (w / 4, 3 * h / 4), (3 * w / 4, 3 * h / 4)]
        return points.map { classify(pixel(cg, x: $0.0, y: $0.1)) }
    }

    /// CGImage の 1 画素 (x,y) の RGBA を読む。
    private func pixel(_ cg: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(cg.height - 1 - y),
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func classify(_ p: (r: Int, g: Int, b: Int)) -> Corner {
        let hi = 140, lo = 110
        switch (p.r, p.g, p.b) {
        case let (r, g, b) where r > hi && g < lo && b < lo: return .red
        case let (r, g, b) where g > hi && r < lo && b < lo: return .green
        case let (r, g, b) where b > hi && r < lo && g < lo: return .blue
        case let (r, g, b) where r > hi && g > hi && b < lo: return .yellow
        default: return .other
        }
    }

    // MARK: - normalizedUp: 見た目を保ったまま .up へ焼き込む

    func testNormalizedUpBakesOrientationPreservingAppearance() {
        let base = markerImage(width: 120, height: 80)   // 横長・.up
        // EXIF 由来の 4 回転（縦横写真で実際に起きるケース）。
        for orientation: UIImage.Orientation in [.up, .right, .down, .left] {
            let rotated = UIImage(cgImage: base.cgImage!, scale: 1, orientation: orientation)
            let normalized = PHAssetImageLoader.normalizedUp(rotated)

            // (1) 出力は必ず .up（向きが焼き込まれている）。
            XCTAssertEqual(normalized.imageOrientation, .up,
                           "normalizedUp は常に .up を返すべき（orientation=\(orientation.rawValue)）")
            // (2) 見た目（向きを尊重した四隅の色）は入力と一致する＝回転しない/しすぎない。
            XCTAssertEqual(cornerColors(normalized), cornerColors(rotated),
                           "normalizedUp が見た目を変えている（orientation=\(orientation.rawValue)）")
        }
    }

    // MARK: - resizedUp: 縮小しても向き・見た目を保つ

    func testResizedUpKeepsAppearanceAndBoundsSize() {
        let base = markerImage(width: 1200, height: 800)
        let rotated = UIImage(cgImage: base.cgImage!, scale: 1, orientation: .right)   // 縦表示
        let out = PHAssetImageLoader.resizedUp(rotated, maxPixel: 200)

        XCTAssertEqual(out.imageOrientation, .up)
        XCTAssertLessThanOrEqual(max(out.size.width, out.size.height), 200, "長辺は maxPixel 以下に収まるべき")
        // 縮小しても四隅の色の並び（＝向き）は保たれる。
        XCTAssertEqual(cornerColors(out), cornerColors(rotated), "resizedUp が向き/見た目を崩している")
    }

    func testResizedUpNoUpscaleWhenSmaller() {
        let base = markerImage(width: 100, height: 100)   // 既に小さく .up
        let out = PHAssetImageLoader.resizedUp(base, maxPixel: 640)
        // 小さく .up なら拡大しない（そのまま or 同寸）。
        XCTAssertLessThanOrEqual(max(out.size.width, out.size.height), 100)
    }

    // MARK: - orientationSafeSize: 小サイズ要求を 640 下限へ

    func testOrientationSafeSizeFloorsSmallRequests() {
        // 小さい要求（横倒しの原因）は 640 下限へ引き上げる。
        let floored = PHAssetImageLoader.orientationSafeSize(CGSize(width: 240, height: 240))
        XCTAssertGreaterThanOrEqual(floored.width, PHAssetImageLoader.orientationSafePixel)
        XCTAssertGreaterThanOrEqual(floored.height, PHAssetImageLoader.orientationSafePixel)

        // 既に十分大きい要求はそのまま（無駄に大きくしない）。
        let large = CGSize(width: 2048, height: 2048)
        XCTAssertEqual(PHAssetImageLoader.orientationSafeSize(large), large)
    }
}
