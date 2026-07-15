import Foundation
import Photos
import SwiftData
import DropboxCore

/// `BackupEngine` の SwiftData レコード/アルバム永続化レイヤー。
/// バックアップ実行ループ（`BackupEngine.swift` の `run`）から呼び出すレコード保存・metadata 構築・
/// アルバム集計をここに集約し、オーケストレーション本体から SwiftData アクセスを切り離す。
extension BackupEngine {

    /// バックアップ済みの「ローカル localIdentifier → Dropbox path」対応。
    /// 自動アルバムのローカル↔クラウド重複排除（BackupLinkProvider）に使う。
    public func localToCloudPaths() -> [String: String] {
        guard let context = modelContext,
              let records = try? context.fetch(FetchDescriptor<BackupAssetRecord>()) else { return [:] }
        var map: [String: String] = [:]
        for record in records {
            if let id = record.localIdentifier { map[id] = record.dropboxPath }
        }
        return map
    }

    /// `localToCloudPaths` の**オフメイン版**（自動アルバム生成用）。バックアップ記録が多いと
    /// 全件 materialize がメインを塞ぐため、使い捨て `ModelContext` を Task.detached で回す。
    nonisolated public func localToCloudPathsDetached() async -> [String: String] {
        guard let container = await MainActor.run(body: { modelContext?.container }) else { return [:] }
        return await Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            guard let records = try? ctx.fetch(FetchDescriptor<BackupAssetRecord>()) else { return [:] }
            var map: [String: String] = [:]
            for record in records {
                if let id = record.localIdentifier { map[id] = record.dropboxPath }
            }
            return map
        }.value
    }

    // MARK: - SwiftData helpers

    func saveRecord(
        dropboxPath: String, asset: PHAsset, filename: String,
        people: [String], albums: [String], isFavorite: Bool,
        contentHash: String? = nil
    ) {
        guard let context = modelContext else { return }
        let path = dropboxPath.lowercased()
        let descriptor = FetchDescriptor<BackupAssetRecord>(
            predicate: #Predicate { $0.dropboxPath == path }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.people     = people
            existing.albums     = albums
            existing.isFavorite = isFavorite
            existing.backedUpAt = Date()
            if let contentHash { existing.contentHash = contentHash }
        } else {
            context.insert(BackupAssetRecord(
                dropboxPath: dropboxPath, localIdentifier: asset.localIdentifier,
                filename: filename, creationDate: asset.creationDate,
                contentHash: contentHash, people: people, albums: albums, isFavorite: isFavorite
            ))
        }
        try? context.save()
    }

    // MARK: - Album query

    /// SwiftData から BackupAssetRecord を読み込み、albumInfos / recordCount を更新する。
    /// ビュー表示時とバックアップ完了後に呼び出す。
    public func loadAlbums() async {
        await Task.yield()   // 呼び出し元の初回レンダリングを先に通す

        guard let context = modelContext else {
            addLog("[albums] modelContext is nil — ModelContainer failed to init. " +
                   "Reinstall the app if this persists.")
            isAlbumsLoaded = true
            return
        }

        let records: [BackupAssetRecord]
        do {
            records = try context.fetch(FetchDescriptor<BackupAssetRecord>())
        } catch {
            addLog("[albums] SwiftData fetch failed: \(error.localizedDescription)")
            isAlbumsLoaded = true
            return
        }

        recordCount = records.count
        let withAlbums = records.filter { !$0.albums.isEmpty }.count
        addLog("[albums] records: \(records.count), with album tags: \(withAlbums)")

        var byAlbum: [String: [BackupAssetRecord]] = [:]
        for record in records {
            for name in record.albums {
                byAlbum[name, default: []].append(record)
            }
        }

        let built = byAlbum.map { name, recs -> BackupAlbumInfo in
            let ids = recs.compactMap { $0.localIdentifier }
            let sorted = recs.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return BackupAlbumInfo(
                name: name,
                photoCount: recs.count,
                coverLocalIdentifier: sorted.last?.localIdentifier,
                localIdentifiers: ids
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        albumInfos = built
        isAlbumsLoaded = true
        addLog("[albums] built \(built.count) album(s): \(built.map(\.name).joined(separator: ", "))")
    }
}
