#if canImport(UIKit)
import UIKit

/// `NSCache` を薄くラップしたインメモリ画像キャッシュ。
///
/// `NSCache` 自体がスレッドセーフなため、actor / @MainActor のどちらの所有者からでも
/// そのまま使える（`@unchecked Sendable`）。破棄ポリシー（LRU 等）は持たず、メモリ層の
/// 共通プリミティブとして LocalPhotoKit / DropboxCore の両キャッシュから利用する。
public final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    /// - Parameters:
    ///   - totalCostLimit: 総コスト上限（バイト）。0 は無制限。
    ///   - countLimit: 件数上限。0 は無制限。
    public init(totalCostLimit: Int = 0, countLimit: Int = 0) {
        if totalCostLimit > 0 { cache.totalCostLimit = totalCostLimit }
        if countLimit > 0 { cache.countLimit = countLimit }
    }

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// - Parameter cost: 概ねのバイト数。`totalCostLimit` ベースの破棄に使われる。
    public func insert(_ image: UIImage, forKey key: String, cost: Int = 0) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    public func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    public func setTotalCostLimit(_ bytes: Int) {
        cache.totalCostLimit = bytes
    }

    public func setCountLimit(_ count: Int) {
        cache.countLimit = count
    }
}
#endif
