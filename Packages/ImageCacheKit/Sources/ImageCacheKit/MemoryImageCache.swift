#if canImport(UIKit)
import UIKit

/// `NSCache` を薄くラップしたインメモリ画像キャッシュ。
///
/// `NSCache` 自体がスレッドセーフなため、actor / @MainActor のどちらの所有者からでも
/// そのまま使える（`@unchecked Sendable`）。破棄ポリシー（LRU 等）は持たず、メモリ層の
/// 共通プリミティブとして LocalPhotoKit / DropboxCore の両キャッシュから利用する。
public final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()
    private var memoryWarningObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - totalCostLimit: 総コスト上限（バイト）。0 は無制限。
    ///   - countLimit: 件数上限。0 は無制限。
    public init(totalCostLimit: Int = 0, countLimit: Int = 0) {
        if totalCostLimit > 0 { cache.totalCostLimit = totalCostLimit }
        if countLimit > 0 { cache.countLimit = countLimit }
        // メモリ圧迫時はデコード済み画像を即解放する。NSCache も自動応答するが、
        // 明示的に全消去して常駐ピークを確実に下げる（再取得はディスク/PHImageManager から）。
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    public func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    /// - Parameter cost: 概ねのバイト数。`totalCostLimit` ベースの破棄に使われる。
    public func insert(_ image: UIImage, forKey key: String, cost: Int = 0) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// デコード済み画像の**実バックストアサイズ**（幅 px × 高さ px × 4byte）をコストに用いて挿入する。
    /// JPEG バイト数ではなく実メモリでコスト計上するため、`totalCostLimit` が実際の常駐量を
    /// 正しく制限できる（JPEG 換算では約10倍以上に膨らんでいた）。
    public func insertDecoded(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
    }

    /// デコード済み画像が占めるおおよそのバイト数（幅 px × 高さ px × 4byte/px）。
    public static func decodedCost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return max(0, Int(pixels.rounded())) * 4
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
