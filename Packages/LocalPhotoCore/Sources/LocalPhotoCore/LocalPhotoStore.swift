import Observation
import Photos

@MainActor
@Observable
public final class LocalPhotoStore {
    public private(set) var assets: [PHAsset] = [] {
        didSet { items = assets.map { LocalPhotoItem(asset: $0) } }
    }
    /// PhotoStore 用アイテム。`assets` 設定時に一度だけ構築してキャッシュする
    /// （SwiftUI が毎レンダーで読むため、computed の `map` を都度実行しないようメモ化）。
    public private(set) var items: [LocalPhotoItem] = []
    public private(set) var authorizationStatus: PHAuthorizationStatus
    var loadCompleted = false

    @ObservationIgnored private let metadataPreloader = MetadataPreloader()

    // MARK: - サムネイル取得 / 先読み（PHCachingImageManager）

    /// サムネイル取得と先読みを同一インスタンスで行う（キャッシュはインスタンス毎のため）。
    @ObservationIgnored let imageManager = PHCachingImageManager()
    /// 先読み中の窓（FIFO）。古い窓は stopCaching してメモリを有界に保つ。
    @ObservationIgnored private var cachingWindows: [(assets: [PHAsset], size: CGSize, options: PHImageRequestOptions)] = []
    private static let maxCachingWindows = 8

    /// requestImage と startCaching で同一の値を使う（キャッシュヒットのため）。
    func makeThumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return options
    }

    /// スクロール先のサムネイルを PHCachingImageManager で先読みする。
    /// 直近 `maxCachingWindows` 窓のみ保持し、古い窓は stopCaching（同一 options で対応付け）。
    func startPrefetch(assets: [PHAsset], targetSize: CGSize) {
        guard !assets.isEmpty else { return }
        let options = makeThumbnailOptions()
        imageManager.startCachingImages(for: assets, targetSize: targetSize,
                                        contentMode: .aspectFill, options: options)
        cachingWindows.append((assets, targetSize, options))
        while cachingWindows.count > Self.maxCachingWindows {
            let old = cachingWindows.removeFirst()
            imageManager.stopCachingImages(for: old.assets, targetSize: old.size,
                                           contentMode: .aspectFill, options: old.options)
        }
    }

    private enum Source {
        case all
        /// BackupAssetRecord から集計した localIdentifier リストで取得する。
        /// PHAssetCollection は使わない（アルバム情報はバックアップ収集データに依存する）。
        case identifiers([String])
    }
    @ObservationIgnored private let source: Source

    /// ライブラリ全体を対象にするイニシャライザ。
    public init() {
        source = .all
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// バックアップ収集データ（BackupAssetRecord）から得た localIdentifier 群を対象にする。
    /// PHAssetCollection は使わず、ID リストで PHAsset を直接フェッチする。
    public init(localIdentifiers: [String]) {
        source = .identifiers(localIdentifiers)
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    public func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if status == .authorized || status == .limited {
            await loadAssets()
        }
    }

    /// 全列挙（数万件の fetch + enumerate + sort）は**メインスレッド外**（Task.detached）で行い、
    /// メインは完成配列の代入のみ。ソース画面を開くたびメインで 67k 列挙して固まるのを防ぐ。
    private func loadAssets() async {
        let source = self.source
        let list = await Task.detached(priority: .userInitiated) { () -> [PHAsset] in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

            switch source {
            case .all:
                let result = PHAsset.fetchAssets(with: options)
                var list: [PHAsset] = []
                list.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in list.append(asset) }
                return list
            case .identifiers(let ids):
                // fetchAssets(withLocalIdentifiers:) は sortDescriptors を無視するため
                // 後段で creationDate 昇順にソートしなおす。
                let unsorted = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                var list: [PHAsset] = []
                list.reserveCapacity(unsorted.count)
                unsorted.enumerateObjects { a, _, _ in list.append(a) }
                list.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                return list
            }
        }.value

        assets = list
        loadCompleted = true
        Task(priority: .utility) { [preloader = metadataPreloader] in
            await preloader.start(assets: list)
        }
    }
}
