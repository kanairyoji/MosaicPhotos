import DropboxCore
import Foundation

/// メタデータ v2 シャードの「ダウンロード → マージ → アップロード」を一元化する（B3）。
/// 旧実装は BackupRunner（バックアップ時のエントリ追記）と OffloadService（オフロード
/// マーカー書き込み）に同じ手順が 2 実装されていた。
struct MetadataShardWriter {
    let uploader: DropboxBackupUploader
    let token: String

    /// 反映の結果。**書けたシャード**と**書けなかったシャード**を分けて返す。
    struct ApplyResult: Sendable {
        /// 書き込みに成功したシャード名（カタログ更新の材料）。
        var written: [String] = []
        /// 書けなかったシャードのエントリ（再送のために呼び出し側が保持する）。
        var failed: [String: [String: DropboxBackupMetadata.Entry]] = [:]
    }

    /// シャードごとの新規/更新エントリを反映する（触ったシャードだけ通信する）。
    ///
    /// ⚠️ **既存シャードの取得に失敗したら書かない**。取得失敗を「空のシャード」と読むと、
    /// 一時的な通信障害で同じ月の既存メタデータ（人物名・アルバム・位置情報）が
    /// 丸ごと失われる（レビュー指摘）。「無い」と「取れなかった」は download 側で区別する。
    /// - Parameter log: 進捗 1 行の通知（"meta/2025-08.json (+3 → 45): OK" 形式）。
    @discardableResult
    func applyEntries(byShard: [String: [String: DropboxBackupMetadata.Entry]],
                      folder: String,
                      log: (String) async -> Void) async -> ApplyResult {
        var result = ApplyResult()
        for (shard, entries) in byShard.sorted(by: { $0.key < $1.key }) {
            let shardPath = folder + BackupMetadataV2.shardSuffix(shard)
            let existing: Data?
            switch await uploader.downloadResult(path: shardPath, token: token) {
            case .found(let data):
                existing = data
            case .notFound:
                existing = nil          // 新規シャード＝空から作ってよい
            case .failure(let reason):
                await log("  meta/\(shard).json: skipped — could not read existing (\(reason))")
                result.failed[shard] = entries
                continue
            }
            let merged = BackupMetadataPlanning.mergedShard(existing: existing, adding: entries)
            let upload = await uploader.uploadJSONResult(merged, to: shardPath, token: token)
            await log("  meta/\(shard).json (+\(entries.count) → \(merged.entries.count)): \(upload.detail)")
            if upload.ok {
                result.written.append(shard)
            } else {
                result.failed[shard] = entries
            }
        }
        return result
    }

    /// 既存エントリへの**部分更新**（オフロードマーカー等）: エントリが無ければ最小形で作る。
    /// `mutate` で各エントリを書き換えてからシャードを書き戻す。
    /// - Returns: シャードを**書けたか**。呼び出し側は失敗を記録して再試行できる。
    @discardableResult
    func updateEntries(paths: [String], folder: String, shardName: String,
                       mutate: (inout DropboxBackupMetadata.Entry) -> Void,
                       makeDefault: (String) -> DropboxBackupMetadata.Entry,
                       log: (String) async -> Void) async -> Bool {
        let shardPath = folder + BackupMetadataV2.shardSuffix(shardName)
        // ⚠️ 取得できなかった回は**書かない**（空で上書きすると既存の記録が消える）。
        var metadata: DropboxBackupMetadata
        switch await uploader.downloadResult(path: shardPath, token: token) {
        case .found(let data):
            metadata = (try? JSONDecoder().decode(DropboxBackupMetadata.self, from: data))
                ?? DropboxBackupMetadata()
        case .notFound:
            metadata = DropboxBackupMetadata()
        case .failure(let reason):
            await log("offload.marker: meta/\(shardName).json skipped — could not read existing (\(reason))")
            return false   // 未送信のまま残し、次回再送する
        }
        for path in paths {
            var entry = metadata.entries[path] ?? makeDefault(path)
            mutate(&entry)
            metadata.entries[path] = entry
        }
        let result = await uploader.uploadJSONResult(metadata, to: shardPath, token: token)
        await log("offload.marker: meta/\(shardName).json (\(paths.count) update(s)): \(result.detail)")
        return result.ok
    }
}
