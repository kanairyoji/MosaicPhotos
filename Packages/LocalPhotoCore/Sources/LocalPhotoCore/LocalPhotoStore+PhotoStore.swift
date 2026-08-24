#if canImport(UIKit)
import ImageCacheKit
import MosaicSupport
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

    /// 2段階サムネイル（プログレッシブ表示）。届いた順にセルへ流す：
    /// 1. キャッシュヒット（メモリ→ディスク）→ 単発で完了
    /// 2. ミス時: 同一アセットの**別サイズ**のメモリキャッシュを暫定表示（ズーム直後を埋める）
    /// 3. PHImageManager（opportunistic）の **degraded（低解像度プレビュー）をそのまま流し**、
    ///    高品質が来たら差し替えて完了（従来は degraded を捨てて高品質まで空白だった）。
    public func thumbnailStages(for item: LocalPhotoItem, targetSize: CGSize) -> AsyncStream<UIImage> {
        let asset = item.asset
        let manager = imageManager
        let options = makeThumbnailOptions()
        let key = "\(asset.localIdentifier):\(Int(targetSize.width))x\(Int(targetSize.height))"

        return AsyncStream { continuation in
            // ⚠️ MainActor で回さない（Task.detached）。スクラブ時は数千要求が並ぶため、MainActor に
            // 載せると UI 処理とキューを奪い合い「キャッシュヒットなのに秒単位待ち」になる
            // （実測: thumb.firstMs 平均 2.9s・ほぼ全部 hit）。PHImageManager はスレッドセーフ、
            // キャッシュは actor、セルへの反映は消費側（MainActor）で行われるので表示は不変。
            let task = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                // センサー: 要求→最初の画像（体感）と→最終画質の遅延。firstYielded で一度だけ記録。
                let t0 = PerfTrace.nowNs()
                var firstYielded = false
                func markFirst() {
                    guard !firstYielded else { return }
                    firstYielded = true
                    PerfTrace.count("thumb.firstMs", value: PerfTrace.msSince(t0))
                }

                // 1) キャッシュ（メモリ→ディスク。デコードは並列・オフメイン）
                if let cached = await ThumbnailCache.shared.get(key) {
                    PerfTrace.count("thumb.hit")
                    markFirst()
                    continuation.yield(cached)
                    return
                }
                PerfTrace.count("thumb.miss")
                if Task.isCancelled { return }

                // 2) 別サイズの暫定表示（最終画質は 3) が差し替える）
                if let near = await ThumbnailCache.shared.nearestMemoryImage(assetID: asset.localIdentifier) {
                    PerfTrace.count("thumb.nearSize")
                    markFirst()
                    continuation.yield(near)
                }
                if Task.isCancelled { return }

                // 3) PHImageManager: degraded → 高品質の順に yield（opportunistic は複数回呼ばれる）
                let box = PHImageRequestBox()
                // ⚠️ 小さい targetSize だと PHImageManager が一部写真で向きの狂った埋め込みサムネを返す
                //    （縦横写真がグリッドで 90° 倒れる／フル画面＝大サイズは正立）。最低 640px で取得し、
                //    表示・キャッシュはセルサイズへ縮小する（保存容量は不変・実測 640 で解消）。
                let reqSize = PHAssetImageLoader.orientationSafeSize(targetSize)
                let final: UIImage? = await withTaskCancellationHandler {
                    await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
                        let requestID = manager.requestImage(
                            for: asset, targetSize: reqSize,
                            contentMode: .aspectFill, options: options
                        ) { img, info in
                            let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                            if isCancelled {
                                if box.markFinished() { cont.resume(returning: nil) }
                                return
                            }
                            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                            if isDegraded {
                                guard !box.finished else { return }
                                if let img {
                                    PerfTrace.count("thumb.degradedFirst")
                                    if box.degradedShownNs == 0 { box.degradedShownNs = PerfTrace.nowNs() }
                                    continuation.yield(img)   // まず見せる
                                }
                                return
                            }
                            if box.markFinished() { cont.resume(returning: img) }
                        }
                        // 登録より先にキャンセルが来ていたら、ここで取り消す（取りこぼし防止）。
                        if box.register(requestID) { manager.cancelImageRequest(requestID) }
                    }
                } onCancel: {
                    if let id = box.cancel() { manager.cancelImageRequest(id) }
                }

                if let final, !Task.isCancelled {
                    // 体感（最初の画像）は degraded が先に出ていればその時刻で計上する。
                    if !firstYielded, box.degradedShownNs != 0 {
                        firstYielded = true
                        PerfTrace.count("thumb.firstMs",
                                        value: Double(box.degradedShownNs &- t0) / 1_000_000)
                    }
                    markFirst()
                    PerfTrace.count("thumb.finalMs", value: PerfTrace.msSince(t0))
                    // 640px で取得した画像をセルサイズへ縮小＋向き .up 焼き込み（保存容量は不変）。
                    let cellPixel = max(targetSize.width, targetSize.height)
                    let oriented = PHAssetImageLoader.resizedUp(final, maxPixel: cellPixel)
                    continuation.yield(oriented)
                    Task.detached(priority: .utility) {
                        await ThumbnailCache.shared.set(oriented, for: key)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    /// 共有用の**原本**。`PHAssetResource` から元のバイト列とファイル名を取り出す。
    ///
    /// ⚠️ 表示用の `fullImage(for:)` は約 2048px へ縮小した UIImage（ビューアはズーム無しで
    /// 十分・メモリ削減のため）。それを共有すると解像度・EXIF・元の形式・元のファイル名が
    /// 失われる（レビュー指摘）。編集済みなら編集後（fullSizePhoto）を優先する。
    /// ※ Live Photo の動画部分は含めない（静止画のみ共有する）。
    nonisolated public func originalForSharing(_ item: LocalPhotoItem) async -> SharedOriginal? {
        let resources = PHAssetResource.assetResources(for: item.asset)
        // 編集済み（fullSizePhoto）→ 原本（photo）の順に選ぶ。どちらも無ければ諦める。
        let resource = resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
        guard let resource else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 上の原本も取りに行く
        var buffer = Data()
        let ok: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                buffer.append(chunk)
            } completionHandler: { error in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: error == nil)
            }
        }
        guard ok, !buffer.isEmpty else { return nil }
        return SharedOriginal(data: buffer, filename: resource.originalFilename)
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
        // 向き安全サムネの契約（640 下限で取得→セルサイズへ縮小＋向き正規化）を共通関数に委譲する。
        // 実フェッチは PHImageManager（下 rawThumbnail）。契約は seam でテスト可能（Layer 2）。
        await PHAssetImageLoader.orientationSafeThumbnail(cellSize: targetSize) { [weak self] reqSize in
            await self?.rawThumbnail(for: asset, targetSize: reqSize)
        }
    }

    /// PHImageManager での素の取得（向き正規化・縮小は呼び出し側 = orientationSafeThumbnail が行う）。
    /// 先読み（startPrefetch）と同じインスタンス・options を使うことでキャッシュにヒットさせる。
    private func rawThumbnail(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
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
