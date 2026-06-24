#if canImport(UIKit)
import CryptoKit
import Foundation
import ImageCacheKit
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
    let thumbnailMemory = MemoryImageCache()

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
        let configuration = ModelConfiguration(
            "DropboxCache",
            schema: schema,
            isStoredInMemoryOnly: isStoredInMemoryOnly
        )
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Falls back to an in-memory store so the cache degrades gracefully
            // (no persistence, but the app keeps working) instead of crashing.
            DropboxLogger.error("DropboxCacheStore: persistent ModelContainer failed: \(error). Falling back to in-memory store.")
            let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            modelContainer = (try? ModelContainer(for: schema, configurations: [memoryConfiguration]))
                ?? (try! ModelContainer(for: schema))
        }
        modelContext = ModelContext(modelContainer)

        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let baseURL = cachesURL.appendingPathComponent("DropboxKit", isDirectory: true)
        thumbnailStore = DiskImageStore(directory: baseURL.appendingPathComponent("thumbnails", isDirectory: true))
        fullImageStore = DiskImageStore(directory: baseURL.appendingPathComponent("fullimages", isDirectory: true))

        self.thumbnailByteLimit = thumbnailByteLimit
        self.fullImageByteLimit = fullImageByteLimit
        thumbnailMemory.setCountLimit(thumbnailMemoryCountLimit)
    }

    // MARK: - Metadata / sync state

    func cachedItems(accountId: String) -> [DropboxFileItem] {
        // 並べ替えは DB 側（SQLite）で行う。捕捉日時の昇順（nil は先頭＝最古扱い）。
        // 67k 件を Swift でソートしないことで CPU と一時配列を削減する。
        let descriptor = FetchDescriptor<CachedDropboxItem>(
            sortBy: [SortDescriptor(\.captureDate, order: .forward)])
        guard let items = try? modelContext.fetch(descriptor) else { return [] }
        let result = items
            .map { DropboxFileItem(path: $0.path, name: $0.name, contentHash: $0.contentHash,
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
#endif
