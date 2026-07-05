#if canImport(UIKit)
import CryptoKit
import Foundation
import ImageCacheKit
import MosaicSupport
import SwiftData
import UIKit

/// Local cache orchestrator for `DropboxPhotoStore`.
///
/// Mirrors the role of `DropboxKeychainStore` as an independent, self-contained
/// component: metadata (file list, sync cursor, cache usage bookkeeping) is
/// persisted with SwiftData, while thumbnail/full-image binaries are kept on
/// disk under `Caches/DropboxKit/` (separated by kind) with an additional
/// `NSCache` memory layer for thumbnails only.
///
/// See `Packages/DropboxKit/docs/interface.md` section 4.2 and
/// `implementation.md` section 8 for the full specification.
///
/// `actor` として実装し、SwiftData(ModelContext)・ファイル I/O・JPEG エンコード・デコードを
/// メインスレッドから切り離す。`@Model`（`CachedDropboxItem` / `DropboxSyncState` /
/// `CacheUsageEntry`）は actor 外へ漏らさず、必ず `Sendable` な値（`DropboxFileItem` /
/// `SyncStateInfo`）へ変換して返す。
///
/// 関心ごとにファイルを分割している：本体は metadata / sync state、バイナリ取得・保存は
/// `DropboxCacheStore+Binary.swift`、使用量記録・LRU 退避・容量設定・無効化は
/// `DropboxCacheStore+Eviction.swift`。extension から参照する格納プロパティ・共有ヘルパは internal。
actor DropboxCacheStore {
    private let modelContainer: ModelContainer
    let modelContext: ModelContext

    // バイナリ層は ImageCacheKit の共通プリミティブに委譲する。
    // 破棄ポリシー（LRU）は本型が SwiftData(CacheUsageEntry) で持つ（mtime ではない）。
    let thumbnailStore: DiskImageStore
    let fullImageStore: DiskImageStore
    let thumbnailMemory: MemoryImageCache
    /// T2: LRU touch のスロットル（5 分窓）と save バッチ化（50 件ごと）の状態。
    var recentTouches: [String: Date] = [:]
    var pendingTouchSaves = 0

    var thumbnailByteLimit: Int
    var fullImageByteLimit: Int

    init(
        thumbnailByteLimit: Int = DropboxInternalConstants.defaultThumbnailByteLimit,
        fullImageByteLimit: Int = DropboxInternalConstants.defaultFullImageByteLimit,
        thumbnailMemoryCountLimit: Int = 0,
        isStoredInMemoryOnly: Bool = false
    ) {
        let schema = Schema([CachedDropboxItem.self, DropboxSyncState.self, CacheUsageEntry.self])
        // ⚠️ 名前を明示して "DropboxCache.store" を使う。
        // 名前なし ModelConfiguration は "default.store" になり、
        // BackupEngine の ModelContainer と衝突してスキーマエラーになる（過去に発生）。
        if isStoredInMemoryOnly {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            modelContainer = (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
        } else {
            modelContainer = Self.makeResilientContainer(name: "DropboxCache", schema: schema)
        }
        modelContext = ModelContext(modelContainer)

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let baseURL = cachesURL.appendingPathComponent("DropboxKit", isDirectory: true)
        thumbnailStore = DiskImageStore(directory: baseURL.appendingPathComponent("thumbnails", isDirectory: true))
        fullImageStore = DiskImageStore(directory: baseURL.appendingPathComponent("fullimages", isDirectory: true))

        self.thumbnailByteLimit = thumbnailByteLimit
        self.fullImageByteLimit = fullImageByteLimit
        // メモリ常駐を有界化：Dropbox サムネは固定サイズ（w128h128・約64KB）。実デコードサイズで
        // コスト計上する `insertDecoded` に合わせ、件数上限＋総コスト上限を設ける。
        // ⚠️ critical 圧迫でも**全消去しない**（purgeOnCritical: false）。全消去すると閲覧中に毎回
        //    ディスクから再デコードする storm になり激重化するため、段階縮小（下限まで）に留める。
        thumbnailMemory = MemoryImageCache(
            totalCostLimit: DropboxInternalConstants.thumbnailMemoryCostLimit,
            countLimit: thumbnailMemoryCountLimit > 0 ? thumbnailMemoryCountLimit
                : DropboxInternalConstants.thumbnailMemoryCountLimit,
            purgeOnCritical: false,
            pressureFloor: DropboxInternalConstants.thumbnailMemoryPressureFloor
        )
    }

    /// 名前付き永続コンテナを作る。壊れた/非互換ストアで失敗したら **store ファイルを削除して作り直し**
    /// （自己修復）、それでも駄目ならインメモリへ。SwiftData が trap せず必ず ModelContainer を返すことで、
    /// 起動時に壊れたストアでクラッシュするのを防ぐ（キャッシュは再同期で回復する）。
    static func makeResilientContainer(name: String, schema: Schema) -> ModelContainer {
        let config = ModelConfiguration(name, schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        DropboxLogger.error("DropboxCacheStore: '\(name)' open failed; deleting store and rebuilding.")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        DropboxLogger.error("DropboxCacheStore: '\(name)' still failing; using in-memory store.")
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
    }

    // MARK: - Metadata / sync state

    func cachedItems(accountId: String) -> [DropboxFileItem] {
        // 計測: SwiftData の全件 fetch + 値型変換の所要（起動・全件表示の重さの一因になりうる）。
        let t0 = PerfTrace.nowNs()
        defer { PerfTrace.logSpan("cache.fetchItems", ms: PerfTrace.msSince(t0)) }
        // 並べ替えは DB 側（SQLite）で行う。捕捉日時の昇順（nil は先頭＝最古扱い）。
        // 67k 件を Swift でソートしないことで CPU と一時配列を削減する。
        let descriptor = FetchDescriptor<CachedDropboxItem>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }
        // ⚠️ contentHash は**渡さない**（nil）。表示用の長寿命配列（67k 件）に 64 桁ハッシュ文字列を
        //    常駐させると数MB級の無駄になる。変更検知は SwiftData 側の `CachedDropboxItem` と
        //    `applyDelta`（delta parser が持つ contentHash）で行うため、表示アイテムには不要。
        let result = items
            .map { DropboxFileItem(path: $0.path, name: $0.name,
                                   captureDate: $0.captureDate, latitude: $0.latitude, longitude: $0.longitude) }
        DropboxLogger.info("cachedItems() → \(result.count) items from SwiftData (accountId=\(accountId))")
        return result
    }

    /// キャッシュ済みアイテム数（全件ロードせず件数だけ）。同期の自己修復判定に使う。
    func cachedItemCount(accountId: String) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>())) ?? 0
    }

    /// 同期状態の Sendable スナップショット（`@Model` を actor 外へ漏らさない）。
    struct SyncStateInfo: Sendable, Equatable {
        let cursor: String?
        let lastSyncedAt: Date?
    }

    func syncStateInfo(accountId: String) -> SyncStateInfo? {
        guard let state = fetchSyncState(accountId: accountId) else { return nil }
        return SyncStateInfo(cursor: state.cursor, lastSyncedAt: state.lastSyncedAt)
    }

    /// 単発取得（get_metadata）で得た位置情報を該当アイテムへ保存する。
    func updateLocation(path: String, latitude: Double, longitude: Double) {
        guard let existing = fetchCachedItem(path: path) else { return }
        existing.latitude = latitude
        existing.longitude = longitude
        try? modelContext.save()
    }

    /// Applies a delta from `list_folder` / `list_folder/continue` to the cache:
    /// removes deleted entries (and their cached binaries), upserts added/changed
    /// entries (invalidating binaries when `contentHash` changed), and stores the
    /// new sync cursor.
    func applyDelta(accountId: String, added: [DropboxFileItem], removed: [String], newCursor: String) {
        DropboxLogger.info("applyDelta() — added=\(added.count), removed=\(removed.count), cursor=\(String(newCursor.prefix(DropboxInternalConstants.cursorLogPrefixLong)))")

        for path in removed {
            if let existing = fetchCachedItem(path: path) {
                modelContext.delete(existing)
            }
            invalidate(path: path)
        }

        var insertCount = 0
        var updateCount = 0
        for item in added {
            if let existing = fetchCachedItem(path: item.path) {
                if existing.contentHash != item.contentHash {
                    invalidate(path: item.path)
                }
                existing.name = item.name
                existing.contentHash = item.contentHash
                existing.captureDate = item.captureDate
                // 位置情報は media_info が pending のとき nil で来るため、既存値を上書きで消さない。
                if item.latitude != nil { existing.latitude = item.latitude }
                if item.longitude != nil { existing.longitude = item.longitude }
                existing.cachedAt = Date()
                updateCount += 1
            } else {
                let newItem = CachedDropboxItem(
                    path: item.path,
                    name: item.name,
                    contentHash: item.contentHash,
                    captureDate: item.captureDate,
                    latitude: item.latitude,
                    longitude: item.longitude
                )
                modelContext.insert(newItem)
                insertCount += 1
            }
        }

        let state = fetchSyncState(accountId: accountId) ?? {
            let newState = DropboxSyncState(accountId: accountId)
            modelContext.insert(newState)
            return newState
        }()
        state.cursor = newCursor
        state.lastSyncedAt = Date()

        try? modelContext.save()
        DropboxLogger.verbose("applyDelta() saved — inserted=\(insertCount), updated=\(updateCount), removed=\(removed.count)")
    }

    // MARK: - Debug snapshot（デバッグ画面用：別コンテナを開かず本アクター経由で読む）

    /// デバッグ画面表示用のスナップショット（件数・使用量・直近アイテム/使用量）。
    /// 以前は DropboxCacheDebugModel が同名 "DropboxCache" ストアを**第2のコンテナ**で開いていたが、
    /// 同一ストアの二重オープンを避けるため、動作中の本アクターから読む。
    func debugSnapshot(accountId: String) -> DropboxCacheDebugSnapshot {
        let allItems = (try? modelContext.fetch(FetchDescriptor<CachedDropboxItem>())) ?? []
        let allUsage = (try? modelContext.fetch(FetchDescriptor<CacheUsageEntry>())) ?? []
        let syncState = fetchSyncState(accountId: accountId)
        let thumbKind = CacheUsageEntry.CacheKind.thumbnail.rawValue
        let fullKind = CacheUsageEntry.CacheKind.fullImage.rawValue
        let thumb = allUsage.filter { $0.kind == thumbKind }
        let full = allUsage.filter { $0.kind == fullKind }

        var itemDesc = FetchDescriptor<CachedDropboxItem>(sortBy: [SortDescriptor(\.cachedAt, order: .reverse)])
        itemDesc.fetchLimit = 50
        let recentItems = ((try? modelContext.fetch(itemDesc)) ?? []).map {
            DropboxCacheDebugSnapshot.Item(path: $0.path, name: $0.name, contentHash: $0.contentHash,
                                           captureDate: $0.captureDate, cachedAt: $0.cachedAt)
        }
        var usageDesc = FetchDescriptor<CacheUsageEntry>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)])
        usageDesc.fetchLimit = 50
        let recentUsage = ((try? modelContext.fetch(usageDesc)) ?? []).map {
            DropboxCacheDebugSnapshot.Usage(key: $0.key, kind: $0.kind, byteSize: $0.byteSize,
                                            lastAccessedAt: $0.lastAccessedAt)
        }

        return DropboxCacheDebugSnapshot(
            itemCount: allItems.count,
            thumbnailCount: thumb.count, thumbnailBytes: thumb.reduce(0) { $0 + $1.byteSize },
            fullImageCount: full.count, fullImageBytes: full.reduce(0) { $0 + $1.byteSize },
            lastSyncedAt: syncState?.lastSyncedAt, syncCursor: syncState?.cursor,
            recentItems: recentItems, recentUsage: recentUsage)
    }

    // MARK: - File naming

    func store(for kind: CacheUsageEntry.CacheKind) -> DiskImageStore {
        kind == .thumbnail ? thumbnailStore : fullImageStore
    }

    // MARK: - SwiftData fetch helpers

    private func fetchCachedItem(path: String) -> CachedDropboxItem? {
        let predicate = #Predicate<CachedDropboxItem> { $0.path == path }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    func fetchSyncState(accountId: String) -> DropboxSyncState? {
        let predicate = #Predicate<DropboxSyncState> { $0.accountId == accountId }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }
}

/// `DropboxCacheStore` のデバッグ用スナップショット（Sendable）。`@Model` を actor 外へ漏らさず値で返す。
public struct DropboxCacheDebugSnapshot: Sendable {
    public struct Item: Sendable {
        public let path: String
        public let name: String
        public let contentHash: String?
        public let captureDate: Date?
        public let cachedAt: Date
    }
    public struct Usage: Sendable {
        public let key: String
        public let kind: String
        public let byteSize: Int
        public let lastAccessedAt: Date
    }
    public let itemCount: Int
    public let thumbnailCount: Int
    public let thumbnailBytes: Int
    public let fullImageCount: Int
    public let fullImageBytes: Int
    public let lastSyncedAt: Date?
    public let syncCursor: String?
    public let recentItems: [Item]
    public let recentUsage: [Usage]
}
#endif
