#if canImport(UIKit)
import Foundation
import Observation
import SwiftData

/// Read-only debug view model for inspecting the DropboxKit SwiftData cache.
///
/// Creates its own `ModelContainer` pointing to the same default SwiftData
/// store as `DropboxCacheStore`. A fresh `ModelContext` is created on each
/// `refresh()` call so reads always reflect the latest persisted state.
@MainActor
@Observable
public final class DropboxCacheDebugModel {
    public struct Stats {
        public let itemCount: Int
        public let thumbnailCount: Int
        public let thumbnailBytes: Int
        public let fullImageCount: Int
        public let fullImageBytes: Int
        public let lastSyncedAt: Date?
        public let syncCursor: String?
    }

    public struct ItemRow: Identifiable {
        public let id: String       // Dropbox path_lower
        public let name: String
        public let contentHash: String?
        public let captureDate: Date?
        public let cachedAt: Date
    }

    public struct UsageRow: Identifiable {
        public let id: String       // "kind:path" key
        public let kind: String     // "thumbnail" | "fullImage"
        public let path: String     // Dropbox path extracted from key
        public let byteSize: Int
        public let lastAccessedAt: Date
    }

    public private(set) var stats: Stats?
    public private(set) var items: [ItemRow] = []
    public private(set) var usageEntries: [UsageRow] = []

    private let container: ModelContainer

    public init() {
        let schema = Schema([CachedDropboxItem.self, DropboxSyncState.self, CacheUsageEntry.self])
        // ⚠️ DropboxCacheStore と同じ "DropboxCache" ストアを読み取る。
        // 名前なしだと "default.store" を開いてしまい、スキーマ競合でデータが見えない。
        let config = ModelConfiguration("DropboxCache", schema: schema, isStoredInMemoryOnly: false)
        container = (try? ModelContainer(for: schema, configurations: [config]))
            ?? (try! ModelContainer(for: schema))
    }

    /// Wipes all SwiftData records and binary cache files, then refreshes stats.
    public func clearAll() {
        let ctx = ModelContext(container)
        if let items = try? ctx.fetch(FetchDescriptor<CachedDropboxItem>()) {
            items.forEach { ctx.delete($0) }
        }
        if let states = try? ctx.fetch(FetchDescriptor<DropboxSyncState>()) {
            states.forEach { ctx.delete($0) }
        }
        if let entries = try? ctx.fetch(FetchDescriptor<CacheUsageEntry>()) {
            entries.forEach { ctx.delete($0) }
        }
        try? ctx.save()

        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxKit", isDirectory: true)
        for sub in ["thumbnails", "fullimages"] {
            let dir = base.appendingPathComponent(sub, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                files.forEach { try? fm.removeItem(at: $0) }
            }
        }
        refresh()
    }

    public func refresh() {
        // Fresh context per call to bypass the in-memory object graph and read
        // the latest data written by DropboxCacheStore's context.
        let ctx = ModelContext(container)

        let allItems = (try? ctx.fetch(FetchDescriptor<CachedDropboxItem>())) ?? []
        let allUsage = (try? ctx.fetch(FetchDescriptor<CacheUsageEntry>())) ?? []
        let syncState = (try? ctx.fetch(FetchDescriptor<DropboxSyncState>()))?.first

        let thumbKind = CacheUsageEntry.CacheKind.thumbnail.rawValue
        let fullKind = CacheUsageEntry.CacheKind.fullImage.rawValue
        let thumbUsage = allUsage.filter { $0.kind == thumbKind }
        let fullUsage = allUsage.filter { $0.kind == fullKind }

        stats = Stats(
            itemCount: allItems.count,
            thumbnailCount: thumbUsage.count,
            thumbnailBytes: thumbUsage.reduce(0) { $0 + $1.byteSize },
            fullImageCount: fullUsage.count,
            fullImageBytes: fullUsage.reduce(0) { $0 + $1.byteSize },
            lastSyncedAt: syncState?.lastSyncedAt,
            syncCursor: syncState?.cursor
        )

        var itemDesc = FetchDescriptor<CachedDropboxItem>(
            sortBy: [SortDescriptor(\.cachedAt, order: .reverse)]
        )
        itemDesc.fetchLimit = 50
        items = ((try? ctx.fetch(itemDesc)) ?? []).map {
            ItemRow(id: $0.path, name: $0.name, contentHash: $0.contentHash,
                    captureDate: $0.captureDate, cachedAt: $0.cachedAt)
        }

        var usageDesc = FetchDescriptor<CacheUsageEntry>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        usageDesc.fetchLimit = 50
        usageEntries = ((try? ctx.fetch(usageDesc)) ?? []).map { entry in
            let path: String
            if let colonIndex = entry.key.firstIndex(of: ":") {
                path = String(entry.key[entry.key.index(after: colonIndex)...])
            } else {
                path = entry.key
            }
            return UsageRow(id: entry.key, kind: entry.kind, path: path,
                            byteSize: entry.byteSize, lastAccessedAt: entry.lastAccessedAt)
        }
    }
}
#endif
