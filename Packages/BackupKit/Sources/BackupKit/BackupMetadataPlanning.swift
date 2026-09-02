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

    /// 既存シャード（クラウドからダウンロードした JSON。**ファイルが無ければ** nil）へ新規分を
    /// マージする。既存キーは新しい値で上書き（再アップロード時に最新のアルバム/人物を反映）。
    ///
    /// ⚠️ **「取れたが読めない」を「無い」と読まない**（レビュー指摘）。取得失敗（通信断）は
    /// 呼び出し側が `.failure` で弾いているが、200 で返ってきた JSON がデコード不能な場合まで
    /// 空へ潰すと、その月の人物名・アルバム・位置情報・オフロードマーカーが**空で上書き**される。
    /// 端末を消すと再生成できない情報なので、読めないときは書かない側に倒す。
    /// - Returns: マージ結果。**既存があるのにデコードできなければ nil**（＝書いてはいけない）。
    static func mergedShard(existing: Data?,
                            adding: [String: DropboxBackupMetadata.Entry]) -> DropboxBackupMetadata? {
        guard let existing else { return DropboxBackupMetadata().merging(adding) }
        guard let base = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: existing) else {
            return nil
        }
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

    /// 既存カタログ（**ファイルが無ければ** nil）へ、今回触ったシャードとアルバム/人物カタログを
    /// 反映する。
    ///
    /// ⚠️ シャードと同じ理由で、**デコード不能な既存カタログを空として上書きしない**
    /// （アルバム名・人物名・シャード一覧・アルバム ID 対応が丸ごと失われる）。
    /// - Returns: 更新結果。**既存があるのにデコードできなければ nil**（＝書いてはいけない）。
    static func updatedCatalog(existing: Data?, touchedShards: [String],
                               albums: [String], people: [String],
                               albumIDs: [String: String]? = nil,
                               deviceID: String? = nil,
                               deviceName: String? = nil) -> BackupCatalog? {
        let base: BackupCatalog
        if let existing {
            guard let decoded = try? JSONDecoder().decode(BackupCatalog.self, from: existing) else {
                return nil
            }
            base = decoded
        } else {
            base = BackupCatalog()
        }
        return base.updating(touchedShards: touchedShards, albums: albums, people: people,
                             albumIDs: albumIDs, deviceID: deviceID, deviceName: deviceName)
    }
}
