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
actor DropboxCacheStore {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    // バイナリ層は ImageCacheKit の共通プリミティブに委譲する。
    // 破棄ポリシー（LRU）は本型が SwiftData(CacheUsageEntry) で持つ（mtime ではない）。
    private let thumbnailStore: DiskImageStore
    private let fullImageStore: DiskImageStore
    private let thumbnailMemory = MemoryImageCache()

    private var thumbnailByteLimit: Int
    private var fullImageByteLimit: Int

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

    /// 保存後の使用量記録＋容量制限を actor 上で行う。
    private func recordStored(kind: CacheUsageEntry.CacheKind, path: String, byteSize: Int) {
        recordUsage(kind: kind, path: path, byteSize: byteSize)
        enforceCapacity(kind: kind)
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

    // MARK: - Usage snapshot (設定表示用)

    /// キャッシュの件数・実ディスク使用量（種別別バイト数）のスナップショット。
    func usageSnapshot() -> DropboxCacheUsage {
        let itemCount = (try? modelContext.fetch(FetchDescriptor<CachedDropboxItem>()))?.count ?? 0
        var thumbBytes = 0
        var fullBytes = 0
        if let entries = try? modelContext.fetch(FetchDescriptor<CacheUsageEntry>()) {
            for entry in entries {
                if entry.kind == CacheUsageEntry.CacheKind.thumbnail.rawValue {
                    thumbBytes += entry.byteSize
                } else {
                    fullBytes += entry.byteSize
                }
            }
        }
        return DropboxCacheUsage(itemCount: itemCount, thumbnailBytes: thumbBytes, fullImageBytes: fullBytes)
    }

    // MARK: - Invalidation / clearing

    /// Discards cached binaries (thumbnail and full image) for `path`, e.g. when
    /// `contentHash` indicates the remote file changed. The `CachedDropboxItem`
    /// metadata record itself is left intact — it is overwritten on the next
    /// `applyDelta` instead, so the entry doesn't disappear from the list while
    /// its image is being re-fetched.
    func invalidate(path: String) {
        removeBinary(kind: .thumbnail, path: path)
        removeBinary(kind: .fullImage, path: path)
        thumbnailMemory.removeImage(forKey: path)
    }

    /// Wipes all cached metadata and binaries. Used on account switches and from
    /// the "Dropbox — Debug" manual clear action.
    ///
    /// Note: `CachedDropboxItem` does not itself carry an `accountId` (the cache
    /// holds at most one account's file list at a time), so clearing always
    /// removes the full metadata set; `accountId` selects which `DropboxSyncState`
    /// row is removed.
    func clearAll(accountId: String) {
        DropboxLogger.info("clearAll() — wiping all metadata and binaries for accountId=\(accountId)")
        if let items = try? modelContext.fetch(FetchDescriptor<CachedDropboxItem>()) {
            for item in items { modelContext.delete(item) }
        }
        if let state = fetchSyncState(accountId: accountId) {
            modelContext.delete(state)
        }
        if let entries = try? modelContext.fetch(FetchDescriptor<CacheUsageEntry>()) {
            for entry in entries { modelContext.delete(entry) }
        }
        try? modelContext.save()

        thumbnailStore.clear()
        fullImageStore.clear()
        thumbnailMemory.removeAll()
        DropboxLogger.info("clearAll() complete")
    }

    // MARK: - File naming

    private func store(for kind: CacheUsageEntry.CacheKind) -> DiskImageStore {
        kind == .thumbnail ? thumbnailStore : fullImageStore
    }

    // MARK: - SwiftData fetch helpers

    private func fetchCachedItem(path: String) -> CachedDropboxItem? {
        let predicate = #Predicate<CachedDropboxItem> { $0.path == path }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    private func fetchSyncState(accountId: String) -> DropboxSyncState? {
        let predicate = #Predicate<DropboxSyncState> { $0.accountId == accountId }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    private func fetchUsageEntry(kind: CacheUsageEntry.CacheKind, path: String) -> CacheUsageEntry? {
        let key = CacheUsageEntry.makeKey(kind: kind, path: path)
        let predicate = #Predicate<CacheUsageEntry> { $0.key == key }
        return try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first
    }

    // MARK: - Usage bookkeeping / LRU eviction

    private func recordUsage(kind: CacheUsageEntry.CacheKind, path: String, byteSize: Int) {
        if let existing = fetchUsageEntry(kind: kind, path: path) {
            existing.byteSize = byteSize
            existing.lastAccessedAt = Date()
        } else {
            let key = CacheUsageEntry.makeKey(kind: kind, path: path)
            modelContext.insert(CacheUsageEntry(key: key, kind: kind, byteSize: byteSize))
        }
        try? modelContext.save()
    }

    private func touchUsage(kind: CacheUsageEntry.CacheKind, path: String) {
        if let existing = fetchUsageEntry(kind: kind, path: path) {
            existing.lastAccessedAt = Date()
            try? modelContext.save()
        } else {
            // Binary exists on disk without a usage record (e.g. created before
            // this bookkeeping was introduced) — backfill one from the file size.
            let size = store(for: kind).fileSize(forName: DropboxCacheNaming.fileName(kind: kind, path: path))
            recordUsage(kind: kind, path: path, byteSize: size)
        }
    }

    private func removeUsageEntry(kind: CacheUsageEntry.CacheKind, path: String) {
        guard let existing = fetchUsageEntry(kind: kind, path: path) else { return }
        modelContext.delete(existing)
        try? modelContext.save()
    }

    private func removeBinary(kind: CacheUsageEntry.CacheKind, path: String) {
        store(for: kind).remove(name: DropboxCacheNaming.fileName(kind: kind, path: path))
        removeUsageEntry(kind: kind, path: path)
    }

    /// Evicts least-recently-accessed entries of `kind` until total usage is
    /// back under the configured byte limit.
    private func enforceCapacity(kind: CacheUsageEntry.CacheKind) {
        let limit = (kind == .thumbnail) ? thumbnailByteLimit : fullImageByteLimit
        let kindRaw = kind.rawValue
        let predicate = #Predicate<CacheUsageEntry> { $0.kind == kindRaw }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.lastAccessedAt, order: .forward)]
        guard let entries = try? modelContext.fetch(descriptor) else { return }

        var total = entries.reduce(0) { $0 + $1.byteSize }
        guard total > limit else { return }

        let prefix = "\(kindRaw):"
        for entry in entries {
            guard total > limit else { break }
            guard entry.key.hasPrefix(prefix) else { continue }
            let path = String(entry.key.dropFirst(prefix.count))
            store(for: kind).remove(name: DropboxCacheNaming.fileName(kind: kind, path: path))
            if kind == .thumbnail {
                thumbnailMemory.removeImage(forKey: path)
            }
            total -= entry.byteSize
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }

    // MARK: - Limit configuration

    func setThumbnailByteLimit(_ limit: Int) {
        thumbnailByteLimit = limit
        enforceCapacity(kind: .thumbnail)
    }

    func setFullImageByteLimit(_ limit: Int) {
        fullImageByteLimit = limit
        enforceCapacity(kind: .fullImage)
    }
}
#endif
