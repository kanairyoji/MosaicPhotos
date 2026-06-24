#if canImport(UIKit)
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
                systemImage: "photo.slash"
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
        let scale = UIScreen.main.scale
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
            PHImageManager.default().requestImage(
                for: item.asset,
                targetSize: PHImageManagerMaximumSize,
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
