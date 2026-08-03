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

    /// 小さい targetSize だと PHImageManager が一部写真で**向きの狂った**埋め込みサムネを返すため、
    /// 取得は最低この画素で行い、表示サイズへ縮小する（グリッド横倒し・顔クロップずれの対策・
    /// 実測: 640 で解消／465 では発生）。UIKit 非依存なので macOS（Photos のみ）でも参照可。
    public static let orientationSafePixel: CGFloat = 640

    /// 取得サイズを orientationSafePixel 下限へ引き上げた正方 target（グリッドの直 requestImage 用）。
    public static func orientationSafeSize(_ target: CGSize) -> CGSize {
        CGSize(width: max(target.width, orientationSafePixel),
               height: max(target.height, orientationSafePixel))
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
        var lastDegraded: UIImage?
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            func finish(_ image: UIImage?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }   // 2 回目以降 / タイムアウトの二重確定を防ぐ
                resumed = true
                cont.resume(returning: image)
            }
            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize, contentMode: contentMode, options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true {
                    // opportunistic の劣化版。**通信可**なら確定版を待つ（ちらつき回避）。
                    // ⚠️ **通信不可**（allowsNetwork=false・背景解析）で iCloud のみの写真は、確定版が
                    //   永遠に来ず withCheckedContinuation が resume されず**永久ハング**する（実障害:
                    //   顔スキャンが最初の iCloud 写真で固まり 0 枚のまま）。その場合はローカルの劣化版で
                    //   確定する（低解像度だがハングしない）。まだ来ていなければ覚えておく。
                    if allowsNetwork {
                        lock.lock(); lastDegraded = image.map(normalizedUp); lock.unlock()
                        return
                    }
                    finish(image.map(normalizedUp))
                    return
                }
                finish(image.map(normalizedUp))
            }
            // 安全弁: どのコールバックでも確定しないまま一定時間が過ぎたら、劣化版（あれば）または nil で
            // 確定する（PHImageManager が確定コールバックを返さない写真で永久ハングしないための最終防壁）。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                lock.lock(); let fallback = lastDegraded; lock.unlock()
                finish(fallback)
            }
        }
    }

    /// 向き安全サムネの**契約**（seam でテスト可能な純関数）。
    /// (1) `cellSize` を orientationSafePixel 下限へ引き上げて `fetch` する（小要求で向きが崩れる
    ///     PHImageManager の挙動を回避）、(2) 得た画像をセルサイズへ縮小＋向き .up 正規化する。
    /// `fetch` は「要求サイズ → 画像」を注入する（本番は PHImageManager、テストは偽装フェッチャ）。
    /// これにより「小要求だと向きの狂った画像を返す fetch」でも出力が正立になることを実機/写真ライブラリ
    /// 無しで検証できる（Layer 2）。
    public static func orientationSafeThumbnail(
        cellSize: CGSize, fetch: (CGSize) async -> UIImage?
    ) async -> UIImage? {
        let raw = await fetch(orientationSafeSize(cellSize))
        return raw.map { resizedUp($0, maxPixel: max(cellSize.width, cellSize.height)) }
    }

    /// UIImage を長辺 maxPixel 以下へ縮小しつつ向きを .up に焼き込む（既に小さく .up ならそのまま）。
    /// 大きめに取得した画像を表示/キャッシュサイズへ落とすのに使う（保存容量は増やさない）。
    public static func resizedUp(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        let needsResize = maxPixel > 0 && longSide > maxPixel
        guard needsResize || image.imageOrientation != .up else { return image }
        let scale = needsResize ? maxPixel / longSide : 1
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// localIdentifier から取得（fetch 込み・正方 target）。`renderFloor` 下限で取得して maxPixel へ縮小
    /// （向き安全化）。CLIP/顔検出など現状の入力を変えたくない経路は `renderFloor: 0` を渡す。
    public static func image(localIdentifier: String?, maxPixel: CGFloat,
                             contentMode: PHImageContentMode = .aspectFit,
                             quality: Quality = .full, allowsNetwork: Bool = true,
                             renderFloor: CGFloat = orientationSafePixel) async -> UIImage? {
        guard let localIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
        else { return nil }
        let reqPixel = max(maxPixel, renderFloor)
        let img = await image(for: asset, targetSize: CGSize(width: reqPixel, height: reqPixel),
                              contentMode: contentMode, quality: quality, allowsNetwork: allowsNetwork)
        guard let img else { return nil }
        return reqPixel > maxPixel ? resizedUp(img, maxPixel: maxPixel) : img
    }

    /// localIdentifier から**向き .up 正規化済み CGImage** を取得する（表示のカバー/顔アバター向け）。
    /// CLIP/顔検出は入力を変えないよう `renderFloor: 0` を渡す（呼び出し側で指定）。
    public static func cgImage(localIdentifier: String?, maxPixel: CGFloat,
                               contentMode: PHImageContentMode = .aspectFit,
                               allowsNetwork: Bool = true,
                               renderFloor: CGFloat = orientationSafePixel) async -> CGImage? {
        await image(localIdentifier: localIdentifier, maxPixel: maxPixel,
                    contentMode: contentMode, quality: .full, allowsNetwork: allowsNetwork,
                    renderFloor: renderFloor)?.cgImage
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
