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

    // 四隅オラクル（マーカー生成・四隅の色）は OrientationOracle に集約（Layer 1/2/3 共用）。
    private func markerImage(width: CGFloat, height: CGFloat) -> UIImage {
        OrientationOracle.markerImage(width: width, height: height)
    }
    private func cornerColors(_ image: UIImage) -> [OrientationOracle.Corner] {
        OrientationOracle.cornerColors(image)
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

    // MARK: - Layer 2: seam で「小要求だと向きが崩れる fetch」を偽装しても出力が正立になる

    /// 画像を 90° 回した**生ピクセル**を `.up` として返す（PHImageManager の「小要求で向きの狂った
    /// サムネを返す」挙動を模す。imageOrientation は .up のまま中身だけ回っている＝再正規化では直らない）。
    private func rotate90PixelsLabeledUp(_ img: UIImage) -> UIImage {
        let size = CGSize(width: img.size.height, height: img.size.width)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: size.width, y: 0)
            c.rotate(by: .pi / 2)
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }

    /// 偽装フェッチャ: 要求サイズが 640 未満なら向きの狂った画像を、640 以上なら正しい画像を返す。
    /// = 今回のバグ（小 targetSize でだけ崩れる）をシミュレートする。要求サイズを記録する。
    private final class FakeFetcher {
        let upright: UIImage
        let rotated: UIImage
        var requestedSizes: [CGSize] = []
        init(upright: UIImage, rotated: UIImage) { self.upright = upright; self.rotated = rotated }
        func fetch(_ size: CGSize) -> UIImage? {
            requestedSizes.append(size)
            return max(size.width, size.height) < PHAssetImageLoader.orientationSafePixel ? rotated : upright
        }
    }

    func testFakeModelsTheBug() {
        // まず偽装が「小要求で向きを崩す」ことを保証（テスト自体の妥当性）。
        let base = markerImage(width: 120, height: 80)
        let rotated = rotate90PixelsLabeledUp(base)
        XCTAssertNotEqual(cornerColors(rotated), cornerColors(base),
                          "rotate90 が向きを崩していない＝この後の Layer2 テストが無意味になる")
    }

    func testOrientationSafeThumbnailStaysUprightDespiteSmallRequestBug() async throws {
        let base = markerImage(width: 120, height: 80)
        let fake = FakeFetcher(upright: base, rotated: rotate90PixelsLabeledUp(base))

        // グリッドのセル相当（640 未満）を要求。契約は 640 下限へ引き上げるので、偽装は正しい画像を返す。
        let cell = CGSize(width: 240, height: 240)
        let out = await PHAssetImageLoader.orientationSafeThumbnail(cellSize: cell) { size in
            fake.fetch(size)
        }

        let result = try XCTUnwrap(out)
        // (1) fetch は 640 下限で呼ばれた（＝バグを踏まない要求サイズ）。
        XCTAssertTrue(fake.requestedSizes.allSatisfy {
            max($0.width, $0.height) >= PHAssetImageLoader.orientationSafePixel
        }, "orientationSafeThumbnail が 640 未満で fetch している（横倒しバグを踏む）")
        // (2) 出力は正立（四隅がマーカーどおり）。契約が小要求へ退行すれば偽装が崩れた画像を返し失敗する。
        XCTAssertEqual(cornerColors(result), cornerColors(base), "出力が横倒し（契約が退行）")
        // (3) 縮小されている（セルサイズ以下）。
        XCTAssertLessThanOrEqual(max(result.size.width, result.size.height), 240)
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
