import AutoAlbumCore
import Photos
import UIKit

// MARK: - Candidate refKeys

/// 端末写真（画像）の refKey 一覧（"L-<localIdentifier>"）。ピープルの顔スキャン候補に使う。
func localImageRefKeys() async -> [String] {
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: opts)
    var keys: [String] = []
    keys.reserveCapacity(assets.count)
    assets.enumerateObjects { asset, _, _ in
        keys.append(PhotoRef.local(asset.localIdentifier).encoded)
    }
    return keys
}

/// お気に入りマークの端末写真（画像）の refKey 集合（"L-…"）。
/// ピープルの代表写真の自動選択（お気に入り優先）に使う。
func favoriteImageRefKeys() async -> Set<String> {
    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(format: "favorite == YES && mediaType == %d", PHAssetMediaType.image.rawValue)
    let assets = PHAsset.fetchAssets(with: opts)
    var keys = Set<String>()
    assets.enumerateObjects { asset, _, _ in
        keys.insert(PhotoRef.local(asset.localIdentifier).encoded)
    }
    return keys
}

// MARK: - Cluster members → local identifiers

/// クラスタのメンバー refKey をローカル localIdentifier 配列へ（クラウドは現状対象外）。
func localIdentifiers(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.localIdentifier }
}

// MARK: - Face avatar

/// 代表顔の写真からアバター（顔の切り抜き）を作る。`box` は Vision の正規化矩形（原点左下）。
func loadFaceAvatar(coverRefKey: String?, box: CGRect?, maxPixel: CGFloat = 600) async -> UIImage? {
    guard let coverRefKey, let box, let localID = PhotoRef.decode(coverRefKey)?.localIdentifier,
          let cg = await requestAspectCGImage(localID, maxPixel: maxPixel) else { return nil }
    let width = CGFloat(cg.width), height = CGFloat(cg.height)
    let margin: CGFloat = 0.35
    var b = box.insetBy(dx: -box.width * margin, dy: -box.height * margin)
        .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    if b.isNull { b = box }
    let pixel = CGRect(
        x: b.minX * width,
        y: (1 - b.minY - b.height) * height,   // Vision(下原点) → CGImage(上原点)
        width: b.width * width,
        height: b.height * height)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard pixel.width >= 1, pixel.height >= 1, let cropped = cg.cropping(to: pixel) else { return nil }
    return UIImage(cgImage: cropped)
}

/// アスペクトを保った端末画像を取得する（顔矩形を重ねて表示するため正方クロップしない）。refKey 版。
func loadLocalAspectImage(refKey: String, maxPixel: CGFloat = 1000) async -> UIImage? {
    guard let localID = PhotoRef.decode(refKey)?.localIdentifier,
          let cg = await requestAspectCGImage(localID, maxPixel: maxPixel) else { return nil }
    return UIImage(cgImage: cg)
}

/// アスペクトを保った CGImage を取得する（顔矩形を正しくマッピングするため正方クロップしない）。
private func requestAspectCGImage(_ localIdentifier: String, maxPixel: CGFloat) async -> CGImage? {
    let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = result.firstObject else { return nil }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = true
    let target = CGSize(width: maxPixel, height: maxPixel)
    let lock = NSLock()
    var didResume = false
    return await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFit, options: options
        ) { image, _ in
            lock.lock(); defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            cont.resume(returning: image?.cgImage)
        }
    }
}
