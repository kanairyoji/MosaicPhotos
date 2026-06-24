#if canImport(UIKit)
import Foundation
import ImageCacheKit
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
            return cached
        }
        let name = DropboxCacheNaming.fileName(kind: .thumbnail, path: path)
        let store = thumbnailStore
        let memory = thumbnailMemory
        await Task.detached(priority: .userInitiated) {
            if let decoded = store.decodedImage(forName: name) {
                memory.insert(decoded, forKey: path)   // NSCache はスレッドセーフ
            }
        }.value
        guard let image = thumbnailMemory.image(forKey: path) else { return nil }
        touchUsage(kind: .thumbnail, path: path)
        return image
    }

    func storeThumbnail(_ image: UIImage, for path: String) {
        thumbnailMemory.insert(image, forKey: path)
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

    /// フル画像をキャッシュから返す。ディスク読み込み＋強制デコードをバックグラウンドで行う。
    func fullImage(for path: String) async -> UIImage? {
        let name = DropboxCacheNaming.fileName(kind: .fullImage, path: path)
        let store = fullImageStore
        let decoded = await Task.detached(priority: .userInitiated) {
            store.decodedImage(forName: name).map(SendableUIImage.init)
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
