import Foundation

/// バックアップ機能の永続設定キー。`dropboxFolder` はホストアプリ（HomeView）も参照するため公開する。
public enum BackupSettingsKeys {
    public static let destination = "backupDestination"
    public static let dropboxFolder = "backupDropboxFolder"
    /// `dropboxFolder` の既定値（アップロード先フォルダ）。
    public static let defaultDropboxFolder = "/MosaicPhotos"
    public static let uploadedLocalIDs = "backupUploadedLocalIDs"
    /// 1 回のバックアップでアップロードする上限枚数（0 = 無制限）。未設定時は既定 10。
    public static let uploadLimit = "backupUploadLimit"
}
