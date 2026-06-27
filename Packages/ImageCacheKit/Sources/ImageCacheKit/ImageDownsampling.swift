#if canImport(UIKit)
import ImageIO
import UIKit

/// 大きな画像を**フルデコードせずに**目標解像度へダウンサンプルするユーティリティ。
///
/// ImageIO の `CGImageSourceCreateThumbnailAtIndex` は元画像の全画素を一旦展開せず、
/// 目標サイズでデコードするため、フル解像度（例 4000×3000×4≒48MB）の巨大な一時バッファを
/// 避けられる。写真ビューアはピンチズームを持たず `scaledToFit` で画面サイズ表示のため、
/// 画面相当へ落としても視覚的な劣化はない。
public enum ImageDownsampling {

    /// 画面表示に十分な最大辺（px）。スマホの fit 表示では 1600px で劣化はほぼ判別不可で、
    /// 1 枚あたりのデコード常駐を抑える（2048→1600 で約36%減）。
    public static let displayMaxPixel: CGFloat = 1600

    /// `data` を最大辺 `maxPixel` に収まるよう（縦横比保持で）ダウンサンプルして返す。
    public static func downsample(data: Data, maxPixel: CGFloat = displayMaxPixel) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF 回転を反映
            kCGImageSourceShouldCacheImmediately: true,         // ここでデコード（メイン外で呼ぶ）
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
#endif
