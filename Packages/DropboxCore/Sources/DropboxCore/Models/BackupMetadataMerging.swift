import Foundation

/// バックアップメタデータの結合（純ロジック・テスト対象）。
///
/// ⚠️ **マージ順序に意味がある**。v1（`.mosaic/metadata.json`）は ADR-38 で**凍結**され、
/// 以後の更新（人物名・アルバム・`offloadedAt` マーカー・位置情報など）は v2 シャードにだけ
/// 書かれる。したがって同一パスの v1 エントリと v2 エントリは**値が異なり得る**——
/// 「後ろほど新しい」順（各ルートの v1 → そのルートのシャード群）で渡すこと。
///
/// 取得は並列（`withTaskGroup`）で行うが、結合はここで**取得完了順ではなく `jsonPaths` の
/// 並び順**に確定させる。完了順に積むと v1 の取得が遅れたときに v1 が v2 を上書きしてしまう。
public enum BackupMetadataMerging {

    /// 「後ろほど新しい」順に並んだメタデータを結合する（nil は欠測＝読み飛ばす）。
    public static func merge(ordered parts: [DropboxBackupMetadata?]) -> DropboxBackupMetadata {
        var out = DropboxBackupMetadata()
        for part in parts {
            guard let part else { continue }
            out = out.merging(part.entries)
        }
        return out
    }
}
