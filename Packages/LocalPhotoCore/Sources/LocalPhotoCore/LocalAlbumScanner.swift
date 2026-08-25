import Foundation
import Observation
import Photos
import PhotoSourceKit

// MARK: - Scanner

/// ローカル写真ライブラリのアルバム構造をスキャンし、キャッシュに保存する。
///
/// - バックアップ機能と完全に独立して動作する。
/// - PHAssetCollection の直接参照はスキャン時（scan()）のみ行い、
///   表示はキャッシュ済みの LocalAlbumInfo を使う。
/// - キャッシュは Application Support/LocalAlbumCache.json に JSON として保存する。
@MainActor
@Observable
public final class LocalAlbumScanner {

    public private(set) var albums: [LocalAlbumInfo] = []
    public private(set) var isLoaded = false
    public private(set) var isScanning = false
    public private(set) var lastScanned: Date?

    /// キャッシュの有効期間。これを超えると次回 loadOrScan() でバックグラウンド再スキャンする。
    private static let cacheTTL: TimeInterval = 60 * 60 * 24  // 24 時間

    // MARK: - 写真ライブラリの変更追従

    /// ⚠️ TTL だけを見ていると、**アルバムへの追加/削除・アルバム名の変更・アルバム自体の
    /// 作成/削除**が最大 24 時間反映されない（件数・カバー・メンバー一覧が古いまま・レビュー指摘）。
    /// 変更通知で印を立て、次回の `loadOrScan()` で再スキャンする。
    @ObservationIgnored private var libraryObserver: PhotoLibraryChangeObserver?
    /// ライブラリが変わった（キャッシュは古い）。
    @ObservationIgnored private var isDirty = false

    public init() {}

    /// 変更監視を始める（多重登録しない）。`loadOrScan()` から自動で呼ばれる。
    private func observeLibraryChanges() {
        guard libraryObserver == nil else { return }
        let observer = PhotoLibraryChangeObserver { [weak self] in
            Task { @MainActor in self?.markDirty() }
        }
        PHPhotoLibrary.shared().register(observer)
        libraryObserver = observer
    }

    private func markDirty() {
        guard !isDirty else { return }
        isDirty = true
        // 表示中なら追従したい。連続する変更をまとめるため少し待ってから走らせる。
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.isDirty, !self.isScanning else { return }
            await self.scan()
        }
    }

    // MARK: - Public API

    /// キャッシュがあればロード、なければスキャンする。
    /// キャッシュが TTL を超えている場合はロード後にバックグラウンドで再スキャンする。
    public func loadOrScan() async {
        observeLibraryChanges()
        if let cached = loadCache() {
            albums      = cached.albums
            lastScanned = cached.scannedAt
            isLoaded    = true
            // TTL 超過、または前回の読み込み以降にライブラリが変わっていたら再スキャンする。
            if LibraryChangeFollowUp.needsRescan(scannedAt: cached.scannedAt, isDirty: isDirty,
                                                 now: Date(), ttl: Self.cacheTTL) {
                Task { await scan() }
            }
        } else {
            await scan()
        }
    }

    /// 写真ライブラリをスキャンして結果をキャッシュに保存する。
    /// 権限がない場合はスキャンをスキップして isLoaded = true を設定する。
    public func scan() async {
        guard !isScanning else { return }
        isScanning = true
        // 走らせる時点の変更は取り込まれる。走行中に来た変更は印が立ち直り、次回に拾う。
        isDirty = false
        defer { isScanning = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            isLoaded = true
            return
        }

        // PHAssetCollection の走査はバックグラウンドで行う。
        // ⚠️ buildLocalAlbums はトップレベル関数である必要がある。
        // Task.detached 内でインスタンスメソッドを呼ぶと @MainActor の型を渡せない
        // コンパイルエラーになる（過去に発生）。
        let scanned = await Task.detached { buildLocalAlbums() }.value
        let now = Date()
        albums      = scanned
        lastScanned = now
        isLoaded    = true
        store.save(LocalAlbumCache(scannedAt: now, albums: scanned))
    }

    // MARK: - Cache persistence

    /// applicationSupport に永続化（Caches と異なり OS に破棄されない）。
    private let store = JSONFileStore<LocalAlbumCache>(
        filename: "LocalAlbumCache.json", in: .applicationSupportDirectory)

    private func loadCache() -> LocalAlbumCache? {
        store.load()
    }
}

// MARK: - Cache model

private struct LocalAlbumCache: Codable {
    let scannedAt: Date
    let albums: [LocalAlbumInfo]
}

// MARK: - Top-level scanner (Task.detached 対応)

// ⚠️ トップレベル関数として定義すること（LocalAlbumScanner のインスタンスメソッドにしない）。
// Task.detached 内で @MainActor 型のインスタンスメソッドを呼ぶとコンパイルエラーになる。
private func buildLocalAlbums() -> [LocalAlbumInfo] {
    let imageFilter = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    let assetOpts = PHFetchOptions()
    assetOpts.predicate = imageFilter

    var result: [LocalAlbumInfo] = []

    let collections = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .albumRegular, options: nil)

    collections.enumerateObjects { collection, _, _ in
        let assets = PHAsset.fetchAssets(in: collection, options: assetOpts)
        guard assets.count > 0 else { return }

        var identifiers: [String] = []
        identifiers.reserveCapacity(assets.count)
        assets.enumerateObjects { a, _, _ in identifiers.append(a.localIdentifier) }

        result.append(LocalAlbumInfo(
            name: collection.localizedTitle ?? "Untitled",
            photoCount: assets.count,
            coverLocalIdentifier: assets.lastObject?.localIdentifier,
            localIdentifiers: identifiers
        ))
    }

    return result.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
