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

    // 圧迫時の段階縮小（E1）用。`configuredCostLimit` は本来の上限（0=無制限）。
    // 圧迫中は totalCostLimit を一時的に絞り、一定時間後に元へ戻す。
    private let stateLock = NSLock()
    private var configuredCostLimit = 0
    private var isUnderPressure = false
    private var restoreWorkItem: DispatchWorkItem?
    /// 圧迫時に確保する最小上限。無制限設定でもこの値まで絞る。
    public static let pressureFloorBytes = 16 * 1024 * 1024
    /// 圧迫後に元の上限へ戻すまでの待ち時間。
    public static let pressureRestoreDelay: TimeInterval = 30

    /// - Parameters:
    ///   - totalCostLimit: 総コスト上限（バイト）。0 は無制限。
    ///   - countLimit: 件数上限。0 は無制限。
    public init(totalCostLimit: Int = 0, countLimit: Int = 0) {
        configuredCostLimit = totalCostLimit
        if totalCostLimit > 0 { cache.totalCostLimit = totalCostLimit }
        if countLimit > 0 { cache.countLimit = countLimit }
        // メモリ圧迫時は全消去せず、上限を一時的に半分（下限あり）へ**段階縮小**する（E1）。
        // NSCache が LRU 的に縮めるため、直近に使ったサムネイルは残り再デコードを減らせる。
        // 一定時間後に元の上限へ戻す。
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleMemoryPressure()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        restoreWorkItem?.cancel()
    }

    // MARK: - Memory pressure (E1: 段階縮小)

    private func handleMemoryPressure() {
        stateLock.lock()
        isUnderPressure = true
        let target = configuredCostLimit > 0
            ? max(Self.pressureFloorBytes, configuredCostLimit / 2)
            : Self.pressureFloorBytes
        restoreWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreAfterPressure() }
        restoreWorkItem = work
        stateLock.unlock()

        cache.totalCostLimit = target   // NSCache が新上限まで LRU で縮める
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressureRestoreDelay, execute: work)
    }

    private func restoreAfterPressure() {
        stateLock.lock()
        isUnderPressure = false
        let restore = configuredCostLimit
        stateLock.unlock()
        cache.totalCostLimit = restore   // 0=無制限へ戻る
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
        stateLock.lock()
        configuredCostLimit = bytes
        let pressured = isUnderPressure
        stateLock.unlock()
        // 圧迫中は縮小状態を維持し、restore 時に新しい configured へ戻す。
        if !pressured { cache.totalCostLimit = bytes }
    }

    public func setCountLimit(_ count: Int) {
        cache.countLimit = count
    }
}
#endif
