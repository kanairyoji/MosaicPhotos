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

    /// **キャッシュ済み（メモリ/ディスク）のサムネだけ**を返す。ネットワークは一切使わない（ADR-88）。
    ///
    /// `thumbnail(for:)` はバッチャ経由で**未キャッシュならダウンロードを待つ**。行列が混んでいると
    /// 1 件 10 秒級になり（実測 diag-34: `thumb.missWaitMs` 平均 10.3 秒）、顔アバターのような
    /// 「出なくてもよいが待たされては困る」用途には使えない。そちらはこの API を使い、
    /// 無ければ即 nil で諦める（必要なら `prefetch` で温める）。
    public func cachedThumbnail(for item: DropboxFileItem) async -> UIImage? {
        await cache.thumbnail(for: item.path)
    }

    /// **顔解析用**: 1024px のサムネを**バッチで**取得する（ADR-90）。
    ///
    /// 表示用（256px）では顔が小さすぎて埋め込みに使えない（実測 diag-35: 到達率 3.8%）。
    /// 解析には 1024px が要るが、**ディスクには保存しない**（68,200 枚 × 約 91KB＝5.9GB になる）。
    /// 呼び出し側がメモリ上で使い捨てる。表示用キャッシュ（256px）は従来どおり別経路で埋まる。
    ///
    /// ⚠️ 1 枚ずつ取ると 1 枚あたり約 0.9 秒＝62,744 枚で実働 17 時間になる（計測値）。
    /// 表示用と同じ `get_thumbnail_batch`（25 枚/リクエスト）に相乗りして往復を潰す。
    public func faceAnalysisThumbnails(paths: [String]) async -> [String: Data] {
        guard !paths.isEmpty else { return [:] }
        var out: [String: Data] = [:]
        for chunk in stride(from: 0, to: paths.count, by: 25).map({
            Array(paths[$0..<min($0 + 25, paths.count)])
        }) {
            guard let body = DropboxThumbnailBatchRequest.encodeBody(
                    paths: chunk, size: DropboxInternalConstants.faceAnalysisAPISize),
                  let data = try? await apiClient.rpc(
                    url: DropboxInternalConstants.getThumbnailBatchURL, jsonBody: body),
                  let results = DropboxThumbnailBatchRequest.decodeResults(from: data, paths: chunk)
            else {
                DropboxLogger.error("faceAnalysisThumbnails() batch failed (\(chunk.count) items)")
                continue
            }
            for (path, imageData) in results {
                if let imageData { out[path] = imageData }
            }
        }
        return out
    }

    /// **計測用**: 任意サイズのサムネイルを 1 枚だけ取得する（ADR-89）。
    ///
    /// 本番の取得経路（`DropboxThumbnailBatcher`）はサイズが固定（`thumbnailAPISize`）で、
    /// キャッシュ・LRU・バッチ集約と結びついている。歩留まり計測は「別サイズを一度だけ見たい」
    /// だけなので、そこへ手を入れず**独立した単発取得**にする。キャッシュにも保存しない。
    /// - Parameter apiSize: Dropbox のサイズ指定（"w256h256" / "w640h480" / "w1024h768" 等）。
    /// - Returns: JPEG バイト列（取得不可は nil）。
    public func measurementThumbnailData(path: String, apiSize: String) async -> Data? {
        struct Arg: Encodable {
            let resource: Resource
            let format = DropboxInternalConstants.thumbnailFormat
            let size: String
            struct Resource: Encodable {
                let tag = ".tag"
                let path: String
                enum CodingKeys: String, CodingKey { case tag = ".tag"; case path }
                func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode("path", forKey: .tag)
                    try c.encode(path, forKey: .path)
                }
            }
        }
        guard let arg = encodeDropboxAPIArg(Arg(resource: .init(path: path), size: apiSize)) else { return nil }
        return try? await apiClient.contentDownload(
            url: DropboxInternalConstants.getThumbnailV2URL, apiArg: arg)
    }

    /// スクロール先サムネイルの先読み。バッチャの**低優先・LIFO・上限つき**プールへ積む。
    /// キャッシュ済み（メモリ/ディスク）は `thumbnailExists` で除外しネットワークを使わない。
    /// 可視セル要求（`thumbnail(for:)`）が常に優先されるため、先読みが表示を遅らせない。
    ///
    /// ⚠️ 先読みは**投機的な自動通信**なので回線ポリシーに従う（ADR-81）。従わないと
    /// 「Wi-Fi のみ」設定でもスクロールしただけでモバイル通信を使ってしまう。
    /// 見えているセルの取得（`thumbnail(for:)`）は前景要求なのでゲートしない
    /// ＝先読みが止まっても表示は続く（オンデマンド取得に degrade するだけ）。
    public func prefetch(_ items: [DropboxFileItem], targetSize: CGSize) {
        guard NetworkStateMonitor.shared.speculativeFetchAllowed() else { return }
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
        // サムネ先読みと同じ理由で回線ポリシーに従う（ADR-81）。フル画像は 1 枚が重いので
        // モバイル通信での取りこぼしは特に効く。表示中の写真の取得（`fullImage`）はゲートしない。
        guard NetworkStateMonitor.shared.speculativeFetchAllowed() else { return }
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

    // MARK: - 共有用の原本

    /// 共有に渡す**原本**（フル解像度・EXIF・元のファイル名）。
    /// 表示用の `fullImage(for:)` は約 2048px へ縮小した UIImage なので、共有には使わない
    /// （解像度・EXIF・元の形式が失われる・レビュー指摘）。
    public func originalData(for item: DropboxFileItem) async -> (data: Data, filename: String)? {
        if let cached = await cache.fullImageData(for: item.path) {
            return (cached, item.name)
        }
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        guard let data = try? await apiClient.contentDownload(
            url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return nil }
        await cache.storeFullImageData(data, for: item.path)   // 原バイト保存（EXIF 保持）
        return (data, item.name)
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
