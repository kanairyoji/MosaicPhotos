import DropboxCore
import Foundation

/// Dropbox 上のフォルダ配置（ADR-175）。**パスを組む場所はここだけ**にする。
///
/// ```
/// /MosaicPhotos/                 ← 唯一のルート（設定 `dropboxFolder`）
///   iPhone-E7EC95/               ← 端末フォルダ（ADR-41・Keychain の短 ID）
///     Backup/                    ← 写真本体と .mosaic メタデータ
///       2025/2025-08/ …          ← 写真は撮影年月で分ける（ADR-176）
///       undated/                 ← 撮影日不明
///       .mosaic/                 ← カタログとシャード（直下のまま）
///     Share/                     ← 共有セット（People-◯◯ / Album-◯◯ …）
/// ```
///
/// ## なぜ 1 つのルートにまとめるか
/// 以前はバックアップ（`/MosaicPhotos`）と共有（`/MosaicShare`）が**別のルート**で、
/// 端末フォルダが 2 箇所に現れ、Dropbox 上で「どこに何があるか」が分かりにくかった。
/// 端末フォルダの下で `Backup` / `Share` に分ければ、端末ごとに 1 箇所を見ればよい。
///
/// ## 既存データは移行しない（ユーザー判断）
/// 旧配置（`/MosaicPhotos/<端末>/直下` と `/MosaicShare/<端末>/`）のファイルは
/// **サーバー上に残す**。台帳はレイアウト版で切り替え、新配置へ上げ直す
/// （`BackupEngine.resetForLayoutChangeIfNeeded`）。旧フォルダの片付けは人が行う。
///
/// ⚠️ **冪等にする**。組み立ての結果が設定へ書き戻ったり、既に配下のパスを渡されたりしても
/// `/Root/iPhone-X/Backup/iPhone-X/Backup/…` と二重にならないこと。二重になると
/// 同じ写真が別パスへ再アップロードされる（旧 `deviceBackupRoot` と同じ注意）。
public enum BackupLayout {

    /// 配置の版。上げると台帳がリセットされ、新配置へ上げ直す。
    /// 1: `<root>/<端末>/` 直下（ADR-41）／ 2: `<root>/<端末>/Backup` ＋ `Share`（ADR-175）
    public static let currentVersion = 2

    public static let backupSubfolder = "Backup"
    public static let shareSubfolder = "Share"

    /// 端末フォルダ: `<root>/<端末>`。
    ///
    /// ⚠️ 既に配下のパス（`<root>/<端末>` や `<root>/<端末>/Backup`）を渡されても
    /// **端末フォルダまで**へ畳む（冪等）。末尾の `Backup` / `Share` は剥がして判定する。
    public static func deviceRoot(root: String, deviceFolder: String) -> String {
        let normalized = stripLayoutSuffix(backupNormalizedPath(root))
        guard !deviceFolder.isEmpty else { return normalized }
        return appendingOnce(normalized, deviceFolder)
    }

    /// バックアップの実保存先: `<root>/<端末>/Backup`。
    /// 端末フォルダが空ならサブフォルダも足さない（旧テスト＝端末フォルダ無しの挙動を保つ）。
    public static func backupRoot(root: String, deviceFolder: String) -> String {
        let device = deviceRoot(root: root, deviceFolder: deviceFolder)
        guard !deviceFolder.isEmpty else { return device }
        return appendingOnce(device, backupSubfolder)
    }

    /// 共有セットの親: `<root>/<端末>/Share`。
    public static func shareRoot(root: String, deviceFolder: String) -> String {
        let device = deviceRoot(root: root, deviceFolder: deviceFolder)
        guard !deviceFolder.isEmpty else { return device }
        return appendingOnce(device, shareSubfolder)
    }

    // MARK: - 写真本体の置き場（撮影年月・ADR-176）

    /// 撮影日不明の写真を入れるフォルダ名。
    public static let undatedFolder = "undated"

    /// 写真 1 枚の置き場: `<backupRoot>/<YYYY>/<YYYY-MM>`（撮影日不明は `<backupRoot>/undated`）。
    ///
    /// ⚠️ なぜ分けるか: 8 万枚を 1 フォルダに置くと、Dropbox の Web/アプリで開くだけで重く、
    /// `list_folder` の一覧取得も長くなる（実フィードバック）。月あたり数百枚に収まる粒度にする。
    /// メタデータのシャード（`.mosaic/meta/<YYYY-MM>.json`）と**同じ切り方**なので、
    /// 「この月の写真とそのメタデータ」が対応する。年で 1 段挟むのは `Backup/` 直下に
    /// 月フォルダが百数十個並ぶのを避けるため。
    ///
    /// 月の決め方は `BackupMetadataV2.shardName(for:)`（**UTC 固定**）と共有する。端末の
    /// タイムゾーンで月が揺れると、同じ写真が別フォルダへ上がり得る。
    public static func photoFolder(backupRoot: String, captureDate: Date?) -> String {
        let shard = BackupMetadataV2.shardName(for: captureDate)
        guard shard != BackupMetadataV2.undatedShardName, shard.count >= 4 else {
            return backupRoot + "/" + undatedFolder
        }
        let year = String(shard.prefix(4))
        return backupRoot + "/" + year + "/" + shard
    }

    /// 末尾が既にその要素なら足さない（大小は Dropbox に合わせて無視）。
    static func appendingOnce(_ base: String, _ component: String) -> String {
        let suffix = "/" + component
        if base.lowercased().hasSuffix(suffix.lowercased()) { return base }
        return base + suffix
    }

    /// 末尾の `Backup` / `Share` を 1 段だけ剥がす（配下のパスを渡されたときの畳み込み用）。
    static func stripLayoutSuffix(_ path: String) -> String {
        for sub in [backupSubfolder, shareSubfolder] {
            let suffix = "/" + sub
            if path.lowercased().hasSuffix(suffix.lowercased()) {
                return String(path.dropLast(suffix.count))
            }
        }
        return path
    }
}
