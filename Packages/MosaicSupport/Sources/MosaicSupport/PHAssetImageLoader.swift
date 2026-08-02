#if canImport(Photos)
import Photos
#if canImport(UIKit)
import UIKit
#endif

/// PHAsset からの画像取得を一元化する共通ローダ。
///
/// これまで `loadLocalCover`（カバー）・`requestAspectCGImage`（顔アバター）・`loadLocalCGImage`
/// （CLIP/顔検出）・グリッドサムネ・キャプション表示などが**各所で個別に** `PHImageManager` を
/// 手書きし、`PHImageRequestOptions`（deliveryMode/resizeMode/network）と**向き正規化の有無**が
/// バラバラだった。これがグリッドサムネ・顔クロップの回転ズレの温床になっていた。
/// 生成点・向き正規化・二重 resume 防止を 1 箇所に集約する。
///
/// `makeOptions`/`Quality` は Photos だけで成立するので macOS テストでも使える。UIImage を返す
/// 取得系は UIKit（実機/シミュレータ）専用。
public enum PHAssetImageLoader {
    /// 取得品質のプリセット。
    public enum Quality {
        /// カバー/フル/AI 解析: 確定版を 1 回だけ返す（劣化版のちらつき無し）。
        case full
        /// グリッドサムネ: 劣化版→確定版の段階配信（体感優先）。ワンショット取得では確定版のみ返る。
        case progressive
    }

    /// 用途に応じた `PHImageRequestOptions` を作る（オプションの唯一の生成点）。
    public static func makeOptions(quality: Quality, allowsNetwork: Bool) -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = quality == .full ? .highQualityFormat : .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = allowsNetwork
        return o
    }

    #if canImport(UIKit)
    /// asset から**向き正規化済み**の UIImage をワンショット取得する。
    /// 劣化版（opportunistic の途中経過）コールバックは無視して確定版だけを返し、
    /// 二重 resume はロックで根絶する（過去に `SWIFT TASK CONTINUATION MISUSE` で実機クラッシュ）。
    public static func image(for asset: PHAsset, targetSize: CGSize,
                             contentMode: PHImageContentMode = .aspectFit,
                             quality: Quality = .full, allowsNetwork: Bool = true) async -> UIImage? {
        let options = makeOptions(quality: quality, allowsNetwork: allowsNetwork)
        let lock = NSLock()
        var resumed = false
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: contentMode, options: options
            ) { image, info in
                // opportunistic の劣化版は待って確定版のみ返す（ちらつき・向き未確定を避ける）。
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }   // 2 回目以降のコールバックは無視
                resumed = true
                cont.resume(returning: image.map(normalizedUp))
            }
        }
    }

    /// localIdentifier から取得（fetch 込み・正方 target）。
    public static func image(localIdentifier: String?, maxPixel: CGFloat,
                             contentMode: PHImageContentMode = .aspectFit,
                             quality: Quality = .full, allowsNetwork: Bool = true) async -> UIImage? {
        guard let localIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        return await image(for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                           contentMode: contentMode, quality: quality, allowsNetwork: allowsNetwork)
    }

    /// localIdentifier から**向き .up 正規化済み CGImage** を取得する（CLIP/顔などピクセル処理向け）。
    public static func cgImage(localIdentifier: String?, maxPixel: CGFloat,
                               contentMode: PHImageContentMode = .aspectFit,
                               allowsNetwork: Bool = true) async -> CGImage? {
        await image(localIdentifier: localIdentifier, maxPixel: maxPixel,
                    contentMode: contentMode, quality: .full, allowsNetwork: allowsNetwork)?.cgImage
    }

    /// UIImage の EXIF 回転を**表示向き（.up）に焼き込んだ** UIImage を返す。
    /// `UIImageView` は imageOrientation を尊重するが、CGImage 直渡し・顔検出座標との突き合わせでは
    /// 生ピクセルのままだと縦横写真がずれるため、常にピクセルを表示向きへ揃える。
    public static func normalizedUp(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// UIImage → 向き .up 正規化した CGImage（旧 `orientationNormalizedCGImage` の置き換え）。
    public static func normalizedUpCGImage(_ image: UIImage) -> CGImage? {
        normalizedUp(image).cgImage
    }
    #endif
}
#endif
