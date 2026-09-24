#if canImport(UIKit)
import MosaicSupport
import UIKit

/// `NSCache` を薄くラップしたインメモリ画像キャッシュ。
///
/// `NSCache` 自体がスレッドセーフなため、actor / @MainActor のどちらの所有者からでも
/// そのまま使える（`@unchecked Sendable`）。破棄ポリシー（LRU 等）は持たず、メモリ層の
/// 共通プリミティブとして LocalPhotoKit / DropboxCore の両キャッシュから利用する。
public final class MemoryImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()
    private var memoryWarningObserver: NSObjectProtocol?
    /// `MemoryPressureMonitor` への解放ハンドラ登録トークン。
    private var pressureToken: Int?

    // 圧迫時の段階縮小（E1）用。`configuredCostLimit` は本来の上限（0=無制限）。
    // 圧迫中は totalCostLimit を一時的に絞り、一定時間後に元へ戻す。
    private let stateLock = NSLock()
    private var configuredCostLimit = 0
    private var isUnderPressure = false
    /// アプリが背面にいるか（背面では上限を下限まで絞る・ADR-226）。
    private var isInBackground = false
    private var restoreWorkItem: DispatchWorkItem?
    /// 圧迫時に確保する最小上限（既定）。無制限設定でもこの値まで絞る。
    public static let pressureFloorBytes = 16 * 1024 * 1024
    /// 圧迫後に元の上限へ戻すまでの待ち時間。
    public static let pressureRestoreDelay: TimeInterval = 30
    /// このインスタンスの圧迫時下限（小さいサムネを多く残したいキャッシュは大きめにする）。
    private let pressureFloor: Int
    /// critical 圧迫で**全消去するか**。サムネキャッシュは false（段階縮小に留め、直近を残して
    /// ディスク再デコードの storm を防ぐ）。重い画像を持つキャッシュは true で素早く解放する。
    private let purgeOnCritical: Bool

    /// - Parameters:
    ///   - totalCostLimit: 総コスト上限（バイト）。0 は無制限。
    ///   - countLimit: 件数上限。0 は無制限。
    ///   - purgeOnCritical: critical 圧迫で全消去するか（既定 true）。サムネは false 推奨。
    ///   - pressureFloor: 圧迫時の下限（バイト・既定 16MB）。サムネは大きめにして保持を効かせる。
    public init(totalCostLimit: Int = 0, countLimit: Int = 0,
                purgeOnCritical: Bool = true,
                pressureFloor: Int = MemoryImageCache.pressureFloorBytes) {
        self.purgeOnCritical = purgeOnCritical
        self.pressureFloor = max(0, pressureFloor)
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

        // DispatchSource 起点の圧迫イベントでも解放する（UIKit 通知が来ないケースを補う）。
        // warning=上限を半減して LRU で縮小 / critical=（purgeOnCritical のとき）即時全消去。
        // サムネキャッシュは purgeOnCritical=false にして全消去せず段階縮小に留める（直近を残し、
        // 閲覧中に毎回ディスク再デコードする storm を防ぐ）。
        registerForBackgroundMode()
        pressureToken = MemoryPressureMonitor.shared.register { [weak self] level in
            guard let self else { return }
            switch level {
            case .warning:
                self.handleMemoryPressure()
            case .critical:
                if self.purgeOnCritical {
                    self.cache.removeAllObjects()   // 重い画像キャッシュは即時全消去
                }
                self.handleMemoryPressure()          // 上限を下限まで絞り restore を予約
            }
        }
    }

    // MARK: - 背面では抱えない（ADR-226）

    /// 生きているキャッシュの一覧（背面/前面の切り替えを配るため・弱参照）。
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [ObjectIdentifier: () -> MemoryImageCache?] = [:]
    nonisolated(unsafe) private static var backgroundMode = false

    /// **アプリが背面に入った／戻った**ことを全キャッシュへ伝える。
    ///
    /// ⚠️ 背面では誰もサムネを見ていないのに、上限（端末の予算の約 5%・60〜192MB）ぶんを
    /// 抱えたまま眠っていた。背面のアプリは footprint の大きい順に落とされる（ADR-223 と同じ理由）ので、
    /// 見ていない画像のために jetsam の的を大きくしているだけ。前面へ戻ったら元の上限に戻す
    /// （中身はディスクに残っているので、再デコードで埋まり直す）。
    public static func setBackgroundMode(_ isBackground: Bool) {
        registryLock.lock()
        backgroundMode = isBackground
        let caches = registry.values.compactMap { $0() }
        registryLock.unlock()
        for cache in caches { cache.applyBackgroundMode(isBackground) }
    }

    private func registerForBackgroundMode() {
        Self.registryLock.lock()
        let id = ObjectIdentifier(self)
        Self.registry[id] = { [weak self] in self }
        let isBackground = Self.backgroundMode
        Self.registryLock.unlock()
        if isBackground { applyBackgroundMode(true) }
    }

    private func applyBackgroundMode(_ isBackground: Bool) {
        stateLock.lock()
        isInBackground = isBackground
        restoreWorkItem?.cancel()
        let target = isBackground ? pressureFloor : configuredCostLimit
        stateLock.unlock()
        cache.totalCostLimit = target
    }

    deinit {
        Self.registryLock.lock()
        Self.registry[ObjectIdentifier(self)] = nil
        Self.registryLock.unlock()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        if let pressureToken {
            MemoryPressureMonitor.shared.unregister(pressureToken)
        }
        restoreWorkItem?.cancel()
    }

    // MARK: - テスト用の覗き口

    var costLimitForTesting: Int { cache.totalCostLimit }
    func restoreAfterPressureForTesting() { restoreAfterPressure() }

    // MARK: - Memory pressure (E1: 段階縮小)

    private func handleMemoryPressure() {
        stateLock.lock()
        isUnderPressure = true
        let target = configuredCostLimit > 0
            ? max(pressureFloor, configuredCostLimit / 2)
            : pressureFloor
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
        // ⚠️ 背面にいる間は**戻さない**（戻すと、誰も見ていない画像のために上限が復活する）。
        let restore = isInBackground ? pressureFloor : configuredCostLimit
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
