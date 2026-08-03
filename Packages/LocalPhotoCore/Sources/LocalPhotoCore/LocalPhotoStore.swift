import MosaicSupport
import Observation
import Photos

@MainActor
@Observable
public final class LocalPhotoStore {
    /// 2-c: 以前は didSet で `assets.map { LocalPhotoItem(...) }`（All で ~18k 割り当て）を
    /// **メインアクタ**で回していた。map は loadAssets 側の detached タスクで作って両方まとめて
    /// 代入する（`setLoaded`）。init（preloaded）は同期経路なので明示設定する。
    public private(set) var assets: [PHAsset] = []
    /// PhotoStore 用アイテム。`assets` と対で設定する（SwiftUI が毎レンダー読むためメモ化）。
    public private(set) var items: [LocalPhotoItem] = []

    /// assets と items を一括更新する（対で保つ・didSet 廃止に伴う唯一の代入経路）。
    private func setLoaded(assets: [PHAsset], items: [LocalPhotoItem]) {
        self.assets = assets
        self.items = items
    }
    public private(set) var authorizationStatus: PHAuthorizationStatus
    var loadCompleted = false

    @ObservationIgnored private let metadataPreloader = MetadataPreloader()

    // MARK: - サムネイル取得 / 先読み（PHCachingImageManager）

    /// サムネイル取得と先読みを同一インスタンスで行う（キャッシュはインスタンス毎のため）。
    /// 先読みは fast 品質のみ準備する（HQ まで事前生成すると先読みの CPU/メモリが跳ね、
    /// スクロール中の本命取得と競合する。HQ は可視セルの requestImage 側で取得される）。
    @ObservationIgnored let imageManager: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = false
        return manager
    }()
    /// 先読み中の窓（FIFO）。古い窓は stopCaching してメモリを有界に保つ。
    @ObservationIgnored private var cachingWindows: [(assets: [PHAsset], size: CGSize, options: PHImageRequestOptions)] = []
    private static let maxCachingWindows = 8

    /// requestImage と startCaching で同一の値を使う（キャッシュヒットのため）。
    func makeThumbnailOptions() -> PHImageRequestOptions {
        // オプションは共通ローダの生成点に統一（段階配信＝progressive）。
        return PHAssetImageLoader.makeOptions(quality: .progressive, allowsNetwork: true)
    }

    /// スクロール先のサムネイルを PHCachingImageManager で先読みする。
    /// 直近 `maxCachingWindows` 窓のみ保持し、古い窓は stopCaching（同一 options で対応付け）。
    func startPrefetch(assets: [PHAsset], targetSize rawTarget: CGSize) {
        guard !assets.isEmpty else { return }
        // 実取得と同じ「向き安全サイズ」で先読みする（サイズ不一致だと先読みキャッシュに当たらない）。
        let targetSize = PHAssetImageLoader.orientationSafeSize(rawTarget)
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
        /// PHAsset を**構築済みで**受け取る（LocalAssetIndex の辞書引き・フェッチ不要）。
        case preloaded
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

    /// 解決済みの PHAsset 群で即座に構築する（アルバムを開く体感高速化）。
    /// `fetchAssets(withLocalIdentifiers:)` はメンバー数が多いと数百 ms 級のライブラリ走査に
    /// なるため、起動時に構築した索引（LocalAssetIndex）の辞書引き結果を直接受け取る。
    /// 並び順は呼び出し側で撮影日昇順に整えて渡す。
    public init(preloadedAssets: [PHAsset]) {
        source = .preloaded
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // 2-d: 撮影日昇順ソート＋LocalPhotoItem の map（大きいアルバムで数千件）を **off-main** で行い、
        // 完成した (assets, items) をメインで一括代入する。索引側（LocalAssetIndex.assets(for:)）は
        // ソートしないので、整列はここに一本化する。準備完了まで items は空＝グリッドは一瞬ロード表示。
        Task { [weak self] in
            let (sorted, mapped) = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [LocalPhotoItem]) in
                let s = preloadedAssets.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                return (s, s.map { LocalPhotoItem(asset: $0) })
            }.value
            guard let self else { return }
            self.setLoaded(assets: sorted, items: mapped)
            self.loadCompleted = true
        }
    }

    public func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if case .preloaded = source { return }   // 構築済み＝フェッチ不要
        if status == .authorized || status == .limited {
            await loadAssets()
        }
    }

    /// 全列挙（数万件の fetch + enumerate + sort）は**メインスレッド外**（Task.detached）で行い、
    /// メインは完成配列の代入のみ。ソース画面を開くたびメインで 67k 列挙して固まるのを防ぐ。
    private func loadAssets() async {
        let source = self.source
        let t0 = CFAbsoluteTimeGetCurrent()
        // 2-c: fetch＋enumerate＋sort に加えて **LocalPhotoItem の map もこの detached 内**で作り、
        // メインには完成した (assets, items) を渡すだけにする（18k 割り当てをメインから外す）。
        let (list, mapped) = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [LocalPhotoItem]) in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

            let list: [PHAsset]
            switch source {
            case .all:
                let result = PHAsset.fetchAssets(with: options)
                var acc: [PHAsset] = []
                acc.reserveCapacity(result.count)
                result.enumerateObjects { asset, _, _ in acc.append(asset) }
                list = acc
            case .preloaded:
                list = []   // requestAccess でガード済み（到達しない）
            case .identifiers(let ids):
                // fetchAssets(withLocalIdentifiers:) は sortDescriptors を無視するため
                // 後段で creationDate 昇順にソートしなおす。
                let unsorted = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                var acc: [PHAsset] = []
                acc.reserveCapacity(unsorted.count)
                unsorted.enumerateObjects { a, _, _ in acc.append(a) }
                acc.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
                list = acc
            }
            return (list, list.map { LocalPhotoItem(asset: $0) })
        }.value

        // アルバムを開く体感速度の実測用: identifiers 指定（アルバム/ピープル/AI アルバム）の
        // fetch はライブラリ規模に比例して遅くなり得るため、件数と所要を診断ログに残す。
        if case .identifiers(let ids) = source {
            Diagnostics.mark("local.loadAssets: ids=\(ids.count) → \(list.count) in \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms")
        }
        setLoaded(assets: list, items: mapped)
        loadCompleted = true
        Task(priority: .utility) { [preloader = metadataPreloader] in
            await preloader.start(assets: list)
        }
    }
}
