#if canImport(UIKit)
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// `DropboxPhotoStore` の画像取得（サムネ/フル画像/カバー/EXIF 用元データ/先読み）。
/// キャッシュ（`DropboxCacheStore`）とバッチャ（`DropboxThumbnailBatcher`）・API へ委譲する薄い層。
/// 本体宣言とコレクション/同期管理は `DropboxPhotoStore.swift`。
extension DropboxPhotoStore {

    // MARK: - Thumbnail

    /// サムネイルを返す。取得は `DropboxThumbnailBatcher` に委譲する
    /// （キャッシュ確認・バッチ集約・キャンセル耐性はバッチャ側に集約）。
    public func thumbnail(for item: DropboxFileItem) async -> UIImage? {
        await thumbnailBatcher.thumbnail(for: item)
    }

    /// スクロール先サムネイルの先読み。バッチャの**低優先・LIFO・上限つき**プールへ積む。
    /// キャッシュ済み（メモリ/ディスク）は `thumbnailExists` で除外しネットワークを使わない。
    /// 可視セル要求（`thumbnail(for:)`）が常に優先されるため、先読みが表示を遅らせない。
    public func prefetch(_ items: [DropboxFileItem], targetSize: CGSize) {
        thumbnailBatcher.prefetch(items)
    }

    /// 画面外へスクロールした先読みの取得を取り消す（無駄なネットワーク取得を止める）。
    /// `PhotoCollectionView` の `cancelPrefetchingForItemsAt` から呼ばれる。
    public func cancelPrefetch(_ items: [DropboxFileItem]) {
        thumbnailBatcher.cancelPrefetch(items)
    }

    /// 前後ページのフル画像を**先読み**する（バイト列だけ取得・保存、デコードはしない）。
    /// 低優先で、すでにバイトがあれば何もしない。`beginFullImage` は立てない（背景埋め込みを
    /// 過度に止めないため）。表示時の `fullImage` がこのキャッシュを即ヒットして体感が軽くなる。
    public func prefetchFullImage(for item: DropboxFileItem) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            if await self.cache.fullImageData(for: item.path) != nil { return }
            struct Arg: Encodable { let path: String }
            guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return }
            guard let data = try? await self.apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return }
            await self.cache.storeFullImageData(data, for: item.path)
        }
    }

    // MARK: - Original data (for EXIF)

    /// 元画像の生データ（EXIF を含む）を返す。キャッシュ済みファイル優先、無ければダウンロード。
    /// EXIF 解析（PhotoSourceKit の PhotoExifInfo）は SwiftUI 層（DropboxKit）側で行う。
    public func originalImageData(for item: DropboxFileItem) async -> Data? {
        if let cached = await cache.fullImageData(for: item.path) {
            return cached
        }
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        return try? await apiClient.contentDownload(
            url: DropboxInternalConstants.downloadFileURL, apiArg: argString)
    }

    // MARK: - Full image

    public func fullImage(for item: DropboxFileItem) async -> UIImage? {
        let t0 = PerfTrace.nowNs()   // 計測: フル画像取得（キャッシュヒット or ダウンロード+デコード）
        if let cached = await cache.fullImage(for: item.path) {
            DropboxLogger.verbose("fullImage() cache hit — \(item.name)")
            PerfTrace.logSpan("fullImage.cacheHit", ms: PerfTrace.msSince(t0))
            return cached
        }
        DropboxLogger.verbose("fullImage() downloading from API — \(item.name)")
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        let data: Data
        do {
            data = try await apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString)
        } catch {
            DropboxLogger.error("fullImage() download failed — \(item.name): \(error.localizedDescription)")
            return nil
        }
        // ★ 元バイト列のままキャッシュ（EXIF 保持）。表示用は画面相当へダウンサンプルして
        //   常駐・一時メモリを抑える（ビューアはズーム無し＝フル解像度は不要）。
        await cache.storeFullImageData(data, for: item.path)
        let decoded = await Task.detached(priority: .userInitiated) {
            (ImageDownsampling.downsample(data: data)
                ?? UIImage(data: data).map { $0.preparingForDisplay() ?? $0 })
                .map(SendableUIImage.init)
        }.value
        guard let image = decoded?.image else { return nil }
        DropboxLogger.verbose("fullImage() downloaded \(data.count) bytes — \(item.name)")
        PerfTrace.logSpan("fullImage.download", ms: PerfTrace.msSince(t0), detail: "\(data.count / 1024)KB")
        return image
    }

    // MARK: - Album cover

    /// アルバムのカバー（タイトル写真）用の画像を返す。**128px サムネの拡大ではなく、フル画像から**
    /// `maxPixel` へダウンサンプルして生成するため粗くならない。フル画像バイトはキャッシュ優先で取得し、
    /// 無ければダウンロードして保存（ビューアと共用）。表示サイズ相当へ落とすので常駐メモリも軽い。
    public func coverImage(for item: DropboxFileItem, maxPixel: CGFloat) async -> UIImage? {
        let data: Data
        if let cached = await cache.fullImageData(for: item.path) {
            data = cached
        } else {
            struct Arg: Encodable { let path: String }
            guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
            DropboxActivityMonitor.shared.beginFullImage()
            defer { DropboxActivityMonitor.shared.endFullImage() }
            guard let downloaded = try? await apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return nil }
            await cache.storeFullImageData(downloaded, for: item.path)   // 原バイト保存（EXIF 保持）
            data = downloaded
        }
        // カバーサイズへダウンサンプル（メイン外）。粗いサムネ拡大ではなく原画から作る。
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampling.downsample(data: data, maxPixel: maxPixel).map(SendableUIImage.init)
        }.value?.image
    }
}
#endif
