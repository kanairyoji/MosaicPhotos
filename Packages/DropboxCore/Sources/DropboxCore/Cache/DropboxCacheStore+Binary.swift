#if canImport(UIKit)
import Foundation
import ImageCacheKit
import MosaicSupport
import UIKit

/// `DropboxCacheStore` のバイナリ（サムネイル／フル画像）取得・保存レイヤー。
/// ディスク I/O・JPEG エンコード・強制デコードは detached タスク（actor 外・並列）で行い、
/// 使用量記録（`DropboxCacheStore+Eviction.swift`）だけ actor に戻す。
extension DropboxCacheStore {

    // MARK: - Thumbnail cache (memory → disk)

    /// サムネイルを返す。メモリヒットは即返し、ミス時は**ディスク読み込み＋強制デコードを
    /// detached タスク（actor 外・並列）**で行い、結果をスレッドセーフな `NSCache` に入れて取り出す。
    /// デコード済み画像のみが境界を跨ぐため Sendable 問題を避けられ、actor をブロックしない。
    func thumbnail(for path: String) async -> UIImage? {
        if let cached = thumbnailMemory.image(forKey: path) {
            PerfTrace.count("cache.thumb.memHit")
            return cached
        }
        let name = DropboxCacheNaming.fileName(kind: .thumbnail, path: path)
        let store = thumbnailStore
        let memory = thumbnailMemory
        let t0 = PerfTrace.nowNs()   // 計測: ディスク読み込み＋強制デコードの所要
        // デコード同時数を制限（要求ごとの無制限 detached でスレッド過多→CPU 競合で激遅になるのを防ぐ）。
        await ThumbnailDecode.limiter.acquire()
        await Task.detached(priority: .userInitiated) {
            if let decoded = store.decodedImage(forName: name) {
                memory.insertDecoded(decoded, forKey: path)   // NSCache はスレッドセーフ・実コスト計上
            }
        }.value
        await ThumbnailDecode.limiter.release()
        guard let image = thumbnailMemory.image(forKey: path) else {
            PerfTrace.count("cache.thumb.miss")   // メモリにもディスクにも無い（ネット取得が必要）
            return nil
        }
        PerfTrace.count("cache.thumb.diskHit", value: PerfTrace.msSince(t0))
        touchUsage(kind: .thumbnail, path: path)
        return image
    }

    /// サムネイルがメモリまたはディスクに存在するか（**デコードせず**安価に確認）。
    /// 先読みで「キャッシュ済みは取得不要」を判定し、無駄なネットワーク取得を防ぐ。
    func thumbnailExists(for path: String) -> Bool {
        if thumbnailMemory.image(forKey: path) != nil { return true }
        return thumbnailStore.fileExists(forName: DropboxCacheNaming.fileName(kind: .thumbnail, path: path))
    }

    func storeThumbnail(_ image: UIImage, for path: String) {
        thumbnailMemory.insertDecoded(image, forKey: path)
        let name = DropboxCacheNaming.fileName(kind: .thumbnail, path: path)
        let store = thumbnailStore
        let sendable = SendableUIImage(image)
        // JPEG エンコードとディスク書込みは actor 外（並列）で行い、使用量記録だけ actor に戻す。
        Task.detached(priority: .utility) { [weak self] in
            guard let data = sendable.image.jpegData(compressionQuality: DropboxInternalConstants.thumbnailJPEGQuality) else { return }
            store.write(data, name: name)
            await self?.recordStored(kind: .thumbnail, path: path, byteSize: data.count)
        }
    }

    // MARK: - Full image cache (disk only)

    /// キャッシュ済みフル画像の生データ（EXIF を含む）を返す。EXIF 抽出に使う。
    func fullImageData(for path: String) -> Data? {
        fullImageStore.data(forName: DropboxCacheNaming.fileName(kind: .fullImage, path: path))
    }

    /// フル画像をキャッシュから返す。ディスク読み込み＋ダウンサンプル（画面相当）を
    /// バックグラウンドで行う。ビューアはズーム無しのためフル解像度デコードは不要で、
    /// 常駐・一時メモリを抑える（保存ファイルは原バイトのまま＝EXIF 保持）。
    func fullImage(for path: String) async -> UIImage? {
        let name = DropboxCacheNaming.fileName(kind: .fullImage, path: path)
        let store = fullImageStore
        let decoded = await Task.detached(priority: .userInitiated) { () -> SendableUIImage? in
            guard let data = store.data(forName: name) else { return nil }
            return (ImageDownsampling.downsample(data: data)
                ?? UIImage(data: data).map { $0.preparingForDisplay() ?? $0 })
                .map(SendableUIImage.init)
        }.value
        guard let image = decoded?.image else { return nil }
        touchUsage(kind: .fullImage, path: path)
        return image
    }

    /// フル画像を**元バイト列のまま**保存する。再エンコードしないため EXIF が保持される
    /// （EXIF 抽出はこのキャッシュ済みファイルを読む）。
    func storeFullImageData(_ data: Data, for path: String) {
        let name = DropboxCacheNaming.fileName(kind: .fullImage, path: path)
        let store = fullImageStore
        Task.detached(priority: .utility) { [weak self] in
            store.write(data, name: name)
            await self?.recordStored(kind: .fullImage, path: path, byteSize: data.count)
        }
    }
}
#endif
