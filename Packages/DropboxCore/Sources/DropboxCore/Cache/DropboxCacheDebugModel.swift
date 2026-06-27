#if canImport(UIKit)
import Foundation
import Observation

/// DropboxKit の SwiftData キャッシュを覗くデバッグ用ビューモデル。
///
/// ⚠️ 以前は同名 "DropboxCache" ストアを**自前の第2 ModelContainer**で開いていたが、同一ストアの
/// 二重オープンを避けるため、**動作中の `DropboxPhotoStore`（→ `DropboxCacheStore` アクター）**から
/// スナップショットを読む方式へ変更した。
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

    public init() {}

    /// 動作中ストアからスナップショットを取得して反映する。store が無ければクリア。
    public func refresh(store: DropboxPhotoStore?) async {
        guard let store else { stats = nil; items = []; usageEntries = []; return }
        let snapshot = await store.cacheDebugSnapshot()
        stats = Stats(
            itemCount: snapshot.itemCount,
            thumbnailCount: snapshot.thumbnailCount, thumbnailBytes: snapshot.thumbnailBytes,
            fullImageCount: snapshot.fullImageCount, fullImageBytes: snapshot.fullImageBytes,
            lastSyncedAt: snapshot.lastSyncedAt, syncCursor: snapshot.syncCursor)
        items = snapshot.recentItems.map {
            ItemRow(id: $0.path, name: $0.name, contentHash: $0.contentHash,
                    captureDate: $0.captureDate, cachedAt: $0.cachedAt)
        }
        usageEntries = snapshot.recentUsage.map { entry in
            let path: String
            if let colon = entry.key.firstIndex(of: ":") {
                path = String(entry.key[entry.key.index(after: colon)...])
            } else {
                path = entry.key
            }
            return UsageRow(id: entry.key, kind: entry.kind, path: path,
                            byteSize: entry.byteSize, lastAccessedAt: entry.lastAccessedAt)
        }
    }

    /// 動作中ストア経由で全消去（メタ＋バイナリ＋カーソル）→ 再取得。
    public func clearAll(store: DropboxPhotoStore?) async {
        guard let store else { return }
        await store.clearCache()
        await refresh(store: store)
    }
}
#endif
