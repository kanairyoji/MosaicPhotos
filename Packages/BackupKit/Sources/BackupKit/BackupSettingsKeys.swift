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
    /// オフロードの**実削除**を許可するか（Developer Options のゲート・既定 false＝ドライランのみ）。
    public static let offloadRealDeletionEnabled = "offloadRealDeletionEnabled"
    /// 1 回のオフロードで削除する上限枚数（既定 10・段階導入）。
    public static let offloadMaxPerRun = "offloadMaxPerRun"
}
