#if canImport(UIKit)
import ImageCacheKit
import Photos
import PhotoSourceKit
import UIKit

extension LocalPhotoStore: PhotoStore {
    public typealias Item = LocalPhotoItem

    // `items` は LocalPhotoStore 本体に stored プロパティとして保持（assets 変更時に再構築）。

    public var state: PhotoLoadState {
        switch authorizationStatus {
        case .notDetermined:
            return .idle
        case .denied, .restricted:
            return .needsSetup(
                message: "Photo library access denied.",
                detail: "Please allow access in the Settings app.",
                systemImage: "photo.slash",
                action: .openSystemSettings
            )
        case .authorized, .limited:
            guard loadCompleted else { return .loading }
            return assets.isEmpty ? .empty : .loaded
        @unknown default:
            return .idle
        }
    }

    public func start() async {
        await requestAccess()
    }

    public func retry() async {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    /// お気に入りを PhotoKit へ書き込む（端末写真）。成功で true。
    /// 注: グリッドの即時反映は意図的に行わない（変更監視を入れていないため、全件再ソートを誘発する
    /// ストア更新は避ける）。フル画面側で楽観表示し、グリッドは次回ロードで追従する。
    /// 書き込み権限が無い（読み取り専用許可）場合は false を返す。
    public func setFavorite(_ item: LocalPhotoItem, _ isFavorite: Bool) async -> Bool {
        let asset = item.asset
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = isFavorite
            } completionHandler: { success, _ in
                cont.resume(returning: success)
            }
        }
    }

    // MARK: - Thumbnail

    /// Size-aware thumbnail: memory → disk cache, then PHImageManager at actual cell resolution.
    public func thumbnail(for item: LocalPhotoItem, targetSize: CGSize) async -> UIImage? {
        let key = "\(item.asset.localIdentifier):\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let cached = await ThumbnailCache.shared.get(key) { return cached }

        let image = await requestThumbnail(for: item.asset, targetSize: targetSize)
        if let image { await ThumbnailCache.shared.set(image, for: key) }
        return image
    }

    /// Fallback for protocol conformance; uses a scale-appropriate default size.
    public func thumbnail(for item: LocalPhotoItem) async -> UIImage? {
        // サムネイルは ×2 上限で十分（メモリ削減・グリッドのセル解像度ポリシーと整合）。
        let scale = min(UIScreen.main.scale, 2)
        let side = 256 * scale
        return await thumbnail(for: item, targetSize: CGSize(width: side, height: side))
    }

    // MARK: - Prefetch

    /// スクロール先のサムネイルを `PHCachingImageManager` で先読みする（PhotoStore 既定の
    /// 逐次取得をオーバーライド）。
    public func prefetch(_ items: [LocalPhotoItem], targetSize: CGSize) {
        startPrefetch(assets: items.map(\.asset), targetSize: targetSize)
    }

    // MARK: - EXIF metadata

    /// PHAsset の元データから EXIF を抽出する。解析は PHImageManager のバックグラウンド
    /// コールバック上で行う。ファイル名は PHAssetResource から取得する。
    /// `nonisolated`：PHAssetResource / 元データ取得をメインスレッドで走らせない
    /// （on-demand 取得の "Fetching on demand on the main queue" 警告と hitch を回避）。
    nonisolated public func metadata(for item: LocalPhotoItem) async -> PhotoExifInfo? {
        let asset = item.asset
        let fileName = PHAssetResource.assetResources(for: asset).first?.originalFilename
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                let info = data.map { PhotoExifInfo.parse(from: $0, fileName: fileName) }
                continuation.resume(returning: info)
            }
        }
    }

    nonisolated public func fullImage(for item: LocalPhotoItem) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            // ビューアはズーム無し（scaledToFit で画面表示）なのでフル解像度は不要。
            // 画面相当の境界（約2048px）に収めて 1 枚あたりのデコード常駐を大幅削減する
            // （フル解像度だと 1 枚 40MB 超になり、ページャの前後保持でピークが跳ねる）。
            let max = ImageDownsampling.displayMaxPixel
            PHImageManager.default().requestImage(
                for: item.asset,
                targetSize: CGSize(width: max, height: max),
                contentMode: .aspectFit,
                options: options
            ) { img, _ in
                continuation.resume(returning: img)
            }
        }
    }

    // MARK: - Private

    private func requestThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        // 先読み（startPrefetch）と同じインスタンス・同じ options を使うことでキャッシュにヒットさせる。
        let manager = imageManager
        let options = makeThumbnailOptions()

        final class RequestBox: @unchecked Sendable {
            var id: PHImageRequestID = PHInvalidImageRequestID
            var resumed = false
        }
        let box = RequestBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.id = manager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFill,
                    options: options
                ) { img, info in
                    guard !box.resumed else { return }
                    let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                    if isCancelled {
                        box.resumed = true
                        continuation.resume(returning: nil)
                        return
                    }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    // degraded (低解像度プレビュー) は無視し、高品質コールバックまで待つ。
                    // img == nil の場合はエラーなので即座に nil を返す。
                    if !isDegraded || img == nil {
                        box.resumed = true
                        continuation.resume(returning: img)
                    }
                }
            }
        } onCancel: {
            manager.cancelImageRequest(box.id)
        }
    }
}
#endif
