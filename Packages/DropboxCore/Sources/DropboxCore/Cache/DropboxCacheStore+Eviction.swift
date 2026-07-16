#if canImport(UIKit)
import Foundation
import ImageCacheKit
import SwiftData
import UIKit

/// `DropboxCacheStore` の使用量記録・LRU 容量管理・無効化レイヤー。
/// `CacheUsageEntry`（最終アクセス日時）ベースで種別ごとにバイト上限を超えた分を
/// 最古から退避する。バイナリ保存後の記録（`recordStored`）もここに置く。
extension DropboxCacheStore {

    // MARK: - Usage snapshot (設定表示用)

    /// キャッシュの件数・実ディスク使用量（種別別バイト数）のスナップショット。
    func usageSnapshot() -> DropboxCacheUsage {
        let itemCount = (try? modelContext.fetchCount(FetchDescriptor<CachedDropboxItem>())) ?? 0
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

    // MARK: - Store bookkeeping (called after a binary write)

    /// 保存後の使用量記録＋容量制限を actor 上で行う。
    func recordStored(kind: CacheUsageEntry.CacheKind, path: String, byteSize: Int) {
        recordUsage(kind: kind, path: path, byteSize: byteSize)
        enforceCapacity(kind: kind)
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
        // SyncState は素の accountId 行に加え、フォルダスコープの複合キー行
        //（"accountId|/path"・ADR-44）も持ち得るため、全行を削除する（単一アカウント運用）。
        if let states = try? modelContext.fetch(FetchDescriptor<DropboxSyncState>()) {
            for state in states { modelContext.delete(state) }
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

    // MARK: - SwiftData fetch helper

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

    /// LRU の最終アクセス時刻を更新する。
    /// ★ T2: 従来は**ディスクヒット 1 件ごとに fetch＋save**しており、スクラブ時（数千件/10s）に
    /// SQLite save が actor へ殺到して diskHit の行列（平均 200ms〜1s）を作っていた。
    /// LRU の時刻は分単位で十分なので、(1) 同一エントリは 5 分間再 touch しない、
    /// (2) save は 50 件ごと（＋eviction 前の flush）にまとめる。
    func touchUsage(kind: CacheUsageEntry.CacheKind, path: String) {
        let key = CacheUsageEntry.makeKey(kind: kind, path: path)
        let now = Date()
        if let last = recentTouches[key], now.timeIntervalSince(last) < 300 { return }
        recentTouches[key] = now

        if let existing = fetchUsageEntry(kind: kind, path: path) {
            existing.lastAccessedAt = now
            pendingTouchSaves += 1
            if pendingTouchSaves >= 50 { flushUsageTouches() }
        } else {
            // Binary exists on disk without a usage record (e.g. created before
            // this bookkeeping was introduced) — backfill one from the file size.
            let size = store(for: kind).fileSize(forName: DropboxCacheNaming.fileName(kind: kind, path: path))
            recordUsage(kind: kind, path: path, byteSize: size)
        }
    }

    /// 溜めた touch を保存する（容量チェック・削除の前に呼び、時刻の取りこぼしを防ぐ）。
    func flushUsageTouches() {
        guard pendingTouchSaves > 0 else { return }
        pendingTouchSaves = 0
        try? modelContext.save()
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
        flushUsageTouches()   // 溜めた LRU 時刻を反映してから容量判定する
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
