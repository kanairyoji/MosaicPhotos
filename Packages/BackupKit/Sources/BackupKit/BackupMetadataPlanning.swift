import DropboxCore
import Foundation

/// メタデータ v2（ADR-38）の純ロジック：新規エントリのシャード分割・シャードマージ・カタログ更新。
/// ネットワーク・PHAsset に依存しないので macOS `swift test` で検証する。
enum BackupMetadataPlanning {

    /// アップロードで生まれた新規エントリ 1 件（撮影日からシャードが決まる）。
    struct NewEntry {
        let path: String            // Dropbox パス（小文字正規化済み）
        let date: Date?             // PHAsset.creationDate（シャード決定用）
        let entry: DropboxBackupMetadata.Entry
    }

    /// 新規エントリを撮影月シャードごとにまとめる。
    /// 戻り値: シャード名（"2025-08" / "undated"）→（パス → エントリ）。
    static func groupedByShard(_ entries: [NewEntry]) -> [String: [String: DropboxBackupMetadata.Entry]] {
        var out: [String: [String: DropboxBackupMetadata.Entry]] = [:]
        for e in entries {
            out[BackupMetadataV2.shardName(for: e.date), default: [:]][e.path] = e.entry
        }
        return out
    }

    /// 既存シャード（クラウドからダウンロードした JSON。無ければ nil）へ新規分をマージする。
    /// 既存キーは新しい値で上書き（再アップロード時に最新のアルバム/人物を反映）。
    static func mergedShard(existing: Data?, adding: [String: DropboxBackupMetadata.Entry]) -> DropboxBackupMetadata {
        let base = existing.flatMap { try? JSONDecoder().decode(DropboxBackupMetadata.self, from: $0) }
            ?? DropboxBackupMetadata()
        return base.merging(adding)
    }

    /// metadata v2 からオフロード台帳の再構築候補を取り出す（機種変更・再インストール用）。
    /// **`offloadedAt` マーカーが付いたエントリだけ**が対象＝ユーザーが写真アプリで削除した
    /// 写真をアルバムに蘇らせない（マーカーはアプリのオフロード実行時にのみ付く）。
    static func offloadCandidates(
        from entries: [String: DropboxBackupMetadata.Entry]
    ) -> [(localIdentifier: String, dropboxPath: String, albums: [String],
           captureDate: Date?, contentHash: String?)] {
        let iso = ISO8601DateFormatter()
        return entries.compactMap { path, entry in
            guard entry.offloadedAt != nil, let id = entry.localIdentifier else { return nil }
            return (localIdentifier: id, dropboxPath: path, albums: entry.albums,
                    captureDate: entry.date.flatMap { iso.date(from: $0) },
                    contentHash: entry.contentHash)
        }
    }

    /// 既存カタログ（無ければ nil）へ、今回触ったシャードとアルバム/人物カタログを反映する。
    static func updatedCatalog(existing: Data?, touchedShards: [String],
                               albums: [String], people: [String],
                               albumIDs: [String: String]? = nil,
                               deviceID: String? = nil,
                               deviceName: String? = nil) -> BackupCatalog {
        let base = existing.flatMap { try? JSONDecoder().decode(BackupCatalog.self, from: $0) }
            ?? BackupCatalog()
        return base.updating(touchedShards: touchedShards, albums: albums, people: people,
                             albumIDs: albumIDs, deviceID: deviceID, deviceName: deviceName)
    }
}
