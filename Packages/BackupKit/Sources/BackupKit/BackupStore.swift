import Foundation
import MosaicSupport
import SwiftData

/// バックアップ記録の Sendable 値（actor 境界の外へ @Model を漏らさない・プロジェクト規約）。
public struct BackupRecordLite: Sendable {
    public let dropboxPath: String
    public let localIdentifier: String?
    public let filename: String
    public let creationDate: Date?
    public let contentHash: String?
    public let albums: [String]
    public let isFavorite: Bool
    public let backedUpAt: Date
}

/// BackupKit の SwiftData 永続化を一手に引き受ける actor（A1/B1 リファクタリング）。
///
/// 旧実装は `BackupEngine`（@MainActor）が plain な `ModelContext` を直接使っており、
/// **起動時の全記録 fetch×2・バックアップ中の毎枚 save・照合の全件 fetch がメインスレッド**で
/// 走っていた（AutoAlbumStore で実測 14.5s ハングを起こした「SwiftData をメインで」の同型）。
/// `@ModelActor` は **init したスレッドに executor が束縛される**既知の挙動があるため、
/// 生成は必ず `makeDetached()`（Task.detached 内で init）を使うこと。
@ModelActor
public actor BackupStore {

    /// オフメイン生成ファクトリ（唯一の正しい作り方）。
    /// ⚠️ `BackupStore(modelContainer:)` を MainActor から直接呼ぶと全処理がメインに束縛される。
    public static func makeDetached() async -> BackupStore {
        await Task.detached(priority: .userInitiated) {
            BackupStore(modelContainer: makeContainer())
        }.value
    }

    /// 名前付き永続コンテナ（自己修復）。壊れた/非互換ストアは削除して再構築し、
    /// それでも駄目ならインメモリ（起動を止めない・記録は 409→hash 照合で自然復元）。
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([BackupAssetRecord.self, OffloadRecord.self])
        return makeResilientModelContainer(
            name: "BackupKit", schema: schema,
            openFailedMessage: "BackupStore: 'BackupKit' store open failed; deleting and rebuilding.",
            memoryFallbackMessage: "BackupStore: 'BackupKit' store still failing; using in-memory store.",
            log: { BackupLogger.error($0) })
    }

    // MARK: - Backup records

    /// アップロード成功 1 件の upsert（パスがキー・再アップロードは最新情報で上書き）。
    public func upsertRecord(dropboxPath: String, localIdentifier: String?, filename: String,
                             creationDate: Date?, contentHash: String?,
                             people: [String], albums: [String], isFavorite: Bool) {
        let path = dropboxPath.lowercased()
        let descriptor = FetchDescriptor<BackupAssetRecord>(
            predicate: #Predicate { $0.dropboxPath == path })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.people     = people
            existing.albums     = albums
            existing.isFavorite = isFavorite
            existing.backedUpAt = Date()
            if let contentHash { existing.contentHash = contentHash }
        } else {
            modelContext.insert(BackupAssetRecord(
                dropboxPath: dropboxPath, localIdentifier: localIdentifier,
                filename: filename, creationDate: creationDate,
                contentHash: contentHash, people: people, albums: albums, isFavorite: isFavorite))
        }
        try? modelContext.save()
    }

    /// 全記録（Sendable 値・撮影日昇順）。
    public func allRecordsLite() -> [BackupRecordLite] {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>(
            sortBy: [SortDescriptor(\.creationDate, order: .forward)]))) ?? []
        return records.map { r in
            BackupRecordLite(dropboxPath: r.dropboxPath, localIdentifier: r.localIdentifier,
                             filename: r.filename, creationDate: r.creationDate,
                             contentHash: r.contentHash, albums: r.albums,
                             isFavorite: r.isFavorite, backedUpAt: r.backedUpAt)
        }
    }

    /// 記録にある localIdentifier 集合（済み判定の確かな出典・台帳消失時の自己修復用）。
    public func recordedLocalIdentifiers() -> Set<String> {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        return Set(records.compactMap(\.localIdentifier))
    }

    /// 「ローカル localIdentifier → Dropbox path」対応（自動アルバムの重複排除用）。
    public func localToCloudPaths() -> [String: String] {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var map: [String: String] = [:]
        for record in records {
            if let id = record.localIdentifier { map[id] = record.dropboxPath }
        }
        return map
    }

    /// 照合（reconcile）: Dropbox の実ファイル一覧（path_lower → content_hash）に合わせて
    /// 記録を修復する。実在しない/hash が矛盾する記録は削除。
    /// 戻り値: (照合に合格した localIdentifier 集合, 削除した記録数)。
    public func reconcile(remote: [String: String]) -> (verified: Set<String>, removed: Int) {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var removed = 0
        var verifiedIDs: Set<String> = []
        for record in records {
            let path = record.dropboxPath.lowercased()
            if let remoteHash = remote[path],
               record.contentHash == nil || record.contentHash == remoteHash {
                if let id = record.localIdentifier { verifiedIDs.insert(id) }
            } else {
                modelContext.delete(record)
                removed += 1
            }
        }
        try? modelContext.save()
        return (verifiedIDs, removed)
    }

    /// 全記録の削除（Debug 用・オフロード台帳は対象外）。
    public func deleteAllRecords() {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        records.forEach(modelContext.delete)
        try? modelContext.save()
    }

    /// アルバム集計（記録数・アルバム別インフォ）。Engine の @Observable 状態の材料。
    public func albumSummary() -> (recordCount: Int, albums: [BackupAlbumInfo]) {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var byAlbum: [String: [BackupAssetRecord]] = [:]
        for record in records {
            for name in record.albums {
                byAlbum[name, default: []].append(record)
            }
        }
        let built = byAlbum.map { name, recs -> BackupAlbumInfo in
            let ids = recs.compactMap { $0.localIdentifier }
            let sorted = recs.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return BackupAlbumInfo(name: name, photoCount: recs.count,
                                   coverLocalIdentifier: sorted.last?.localIdentifier,
                                   localIdentifiers: ids)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (records.count, built)
    }

    // MARK: - Offload ledger

    /// オフロード実行の記録（upsert）。
    public func upsertOffloads(_ items: [(localIdentifier: String, dropboxPath: String,
                                          albums: [String], captureDate: Date?, contentHash: String?)]) {
        for item in items {
            let id = item.localIdentifier
            let descriptor = FetchDescriptor<OffloadRecord>(
                predicate: #Predicate { $0.localIdentifier == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                modelContext.delete(existing)
            }
            modelContext.insert(OffloadRecord(localIdentifier: item.localIdentifier,
                                              dropboxPath: item.dropboxPath.lowercased(),
                                              albums: item.albums,
                                              captureDate: item.captureDate,
                                              contentHash: item.contentHash))
        }
        try? modelContext.save()
    }

    /// 台帳からの削除（復元・ロールバック用）。
    public func removeOffloads(localIdentifiers: [String]) {
        let ids = Set(localIdentifiers)
        let all = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        for record in all where ids.contains(record.localIdentifier) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    /// オフロード台帳の集計（アルバム名 → クラウド代替パス・撮影日昇順）＋総件数。
    public func offloadLedgerSnapshot() -> (byAlbum: [String: [String]], count: Int) {
        let records = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        var byAlbum: [String: [(Date?, String)]] = [:]
        for record in records {
            for album in record.albums {
                byAlbum[album, default: []].append((record.captureDate, record.dropboxPath))
            }
        }
        let sorted = byAlbum.mapValues { list in
            list.sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }.map(\.1)
        }
        return (sorted, records.count)
    }
}
