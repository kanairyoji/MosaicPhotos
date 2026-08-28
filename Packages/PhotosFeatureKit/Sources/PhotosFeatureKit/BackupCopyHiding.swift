import Foundation

/// バックアップコピーの二重表示を防ぐ（純ロジック・テスト対象）。
///
/// ⚠️ なぜ要るか（実機 diagnostics-57/58）: 「すべての写真」に古い写真が大量に出るという報告。
/// 実体のパスは `/MosaicPhotos/…`＝**この端末のバックアップフォルダ**だった。
///
/// バックアップフォルダは**意図的に** Dropbox の同期ルートに入っている（`RootView`）。
/// オフロード（端末から消した）写真の「クラウド側の代替」を、ソースフォルダ設定に関わらず
/// 表示できるようにするため（ADR-40）。ところが統合一覧には重複排除が無かったので、
/// **端末にまだ有る写真まで「端末の 1 枚」＋「クラウドの 1 枚」で二重に出ていた**。
/// バックアップが古い写真を上げ進めるほど古い写真が次々に現れる、という見え方になる。
///
/// 方針: バックアップコピーは**端末に原本が無いときだけ**出す。
/// - 原本が有る → 端末の 1 枚だけ出す（クラウドのコピーは隠す）
/// - 原本が無い（オフロード済み・別端末で撮った等）→ クラウドのコピーを出す（代替表示は保つ）
///
/// ⚠️ **対応が分からないものは隠さない**。写真が消えるより重複する方がまだ良い
/// （隠して「無い」と思わせるのは取り返しがつかない）。
public enum BackupCopyHiding {

    /// 隠すべきクラウドパス（小文字）を求める。
    ///
    /// - Parameters:
    ///   - backupPathToLocalID: バックアップ台帳の対応（Dropbox パス小文字 → localIdentifier）。
    ///     空なら何も隠さない（台帳が未構築・別端末のフォルダなど）。
    ///   - localIdentifiers: いま端末に有る写真の localIdentifier。
    /// - Returns: 表示から外すパス（小文字）の集合。
    public static func hiddenPaths(backupPathToLocalID: [String: String],
                                   localIdentifiers: Set<String>) -> Set<String> {
        guard !backupPathToLocalID.isEmpty, !localIdentifiers.isEmpty else { return [] }
        var hidden = Set<String>()
        for (path, localID) in backupPathToLocalID where localIdentifiers.contains(localID) {
            hidden.insert(path)
        }
        return hidden
    }
}
