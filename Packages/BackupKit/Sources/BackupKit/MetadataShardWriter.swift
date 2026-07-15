import DropboxCore
import Foundation

/// メタデータ v2 シャードの「ダウンロード → マージ → アップロード」を一元化する（B3）。
/// 旧実装は BackupRunner（バックアップ時のエントリ追記）と OffloadService（オフロード
/// マーカー書き込み）に同じ手順が 2 実装されていた。
struct MetadataShardWriter {
    let uploader: DropboxBackupUploader
    let token: String

    /// シャードごとの新規/更新エントリを反映する（触ったシャードだけ通信する）。
    /// - Parameter log: 進捗 1 行の通知（"meta/2025-08.json (+3 → 45): OK" 形式）。
    /// - Returns: 触ったシャード名（カタログ更新の材料）。
    @discardableResult
    func applyEntries(byShard: [String: [String: DropboxBackupMetadata.Entry]],
                      folder: String,
                      log: (String) async -> Void) async -> [String] {
        for (shard, entries) in byShard.sorted(by: { $0.key < $1.key }) {
            let shardPath = folder + BackupMetadataV2.shardSuffix(shard)
            let existing = await uploader.download(path: shardPath, token: token)
            let merged = BackupMetadataPlanning.mergedShard(existing: existing, adding: entries)
            let result = await uploader.uploadJSON(merged, to: shardPath, token: token)
            await log("  meta/\(shard).json (+\(entries.count) → \(merged.entries.count)): \(result)")
        }
        return Array(byShard.keys)
    }

    /// 既存エントリへの**部分更新**（オフロードマーカー等）: エントリが無ければ最小形で作る。
    /// `mutate` で各エントリを書き換えてからシャードを書き戻す。
    func updateEntries(paths: [String], folder: String, shardName: String,
                       mutate: (inout DropboxBackupMetadata.Entry) -> Void,
                       makeDefault: (String) -> DropboxBackupMetadata.Entry,
                       log: (String) async -> Void) async {
        let shardPath = folder + BackupMetadataV2.shardSuffix(shardName)
        let existing = await uploader.download(path: shardPath, token: token)
        var metadata = existing.flatMap { try? JSONDecoder().decode(DropboxBackupMetadata.self, from: $0) }
            ?? DropboxBackupMetadata()
        for path in paths {
            var entry = metadata.entries[path] ?? makeDefault(path)
            mutate(&entry)
            metadata.entries[path] = entry
        }
        let result = await uploader.uploadJSON(metadata, to: shardPath, token: token)
        await log("offload.marker: meta/\(shardName).json (\(paths.count) update(s)): \(result)")
    }
}
