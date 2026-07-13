import AutoAlbumCore
import DropboxKit
import Photos
import UIKit

// MARK: - Candidate refKeys

/// 同期済みクラウド写真の refKey 一覧（"C-<path>"）。ピープルの顔スキャン候補（クラウド分）に使う。
/// クラウドはキャッシュ済み 128px サムネで顔検出する（追加DL無し・低解像度＝大きい顔中心）。
@MainActor
func cloudImageRefKeys(dropboxStore: DropboxPhotoStore) -> [String] {
    dropboxStore.items.map { PhotoRef.cloud($0.path).encoded }
}

/// ローカル＋クラウドの画像 refKey（顔スキャン候補の全体）。クラウド同期が未完なら cloud 分は
/// 空になり得るが、夜間 BGTask/再起動の次回スキャンで拾われる（スキャンは未処理分のみの増分）。
@MainActor
func allImageRefKeys(dropboxStore: DropboxPhotoStore) async -> [String] {
    let cloud = cloudImageRefKeys(dropboxStore: dropboxStore)
    return await localImageRefKeys() + cloud
}

/// 端末写真（画像）の refKey 一覧（"L-<localIdentifier>"）。ピープルの顔スキャン候補に使う。
/// ⚠️ アプリ層の top-level 関数はデフォルト MainActor になるため、全件列挙（数万件）は
/// `Task.detached` で**メインスレッド外**へ逃がす（起動直後のホーム描画を固めない）。
func localImageRefKeys() async -> [String] {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: opts)
        var keys: [String] = []
        keys.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            keys.append(PhotoRef.local(asset.localIdentifier).encoded)
        }
        return keys
    }.value
}

/// 端末写真（画像）の総数。顔スキャンの進捗の分母（AI 解析の状況画面）に使う。
/// `fetchAssets(...).count` は遅延評価なので列挙より軽い。取得はメインスレッド外。
func localImagePhotoCount() async -> Int {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        return PHAsset.fetchAssets(with: opts).count
    }.value
}

/// お気に入りマークの端末写真（画像）の refKey 集合（"L-…"）。
/// ピープルの代表写真の自動選択（お気に入り優先）に使う。列挙はメインスレッド外。
func favoriteImageRefKeys() async -> Set<String> {
    await Task.detached(priority: .utility) {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "favorite == YES && mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: opts)
        var keys = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            keys.insert(PhotoRef.local(asset.localIdentifier).encoded)
        }
        return keys
    }.value
}

// MARK: - Cluster members → local identifiers

/// クラスタのメンバー refKey をローカル localIdentifier 配列へ。
func localIdentifiers(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.localIdentifier }
}

/// クラスタのメンバー refKey をクラウド（Dropbox）path 配列へ。人物アルバムのクラウドメンバー表示用。
func cloudPaths(from refKeys: [String]) -> [String] {
    refKeys.compactMap { PhotoRef.decode($0)?.cloudPath }
}

// MARK: - Face avatar

/// 代表顔の写真からアバター（顔の切り抜き）を作る。`box` は Vision の正規化矩形（原点左下）。
func loadFaceAvatar(coverRefKey: String?, box: CGRect?, maxPixel: CGFloat = 600) async -> UIImage? {
    guard let coverRefKey, let box, let ref = PhotoRef.decode(coverRefKey) else { return nil }
    let source: CGImage?
    if let localID = ref.localIdentifier {
        source = await requestAspectCGImage(localID, maxPixel: maxPixel)
    } else if let path = ref.cloudPath {
        // クラウド顔: Dropbox のキャッシュ済み 128px サムネから切り抜く（低解像度アバター・追加DL無し）。
        source = await HeavyWorkScheduler.stores?.dropboxStore.thumbnail(for: dropboxFileItem(path: path))?.cgImage
    } else {
        source = nil
    }
    guard let cg = source else { return nil }
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
