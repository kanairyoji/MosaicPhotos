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
    /// 自動オフロードの発動条件（空き容量のしきい値 MB・0 = オフロードしない）。
    /// ⚠️ 自動オフロード本体は未実装。UI は選択時に案内を出して 0 へ戻す（先行して設定枠だけ用意）。
    public static let offloadAutoThresholdMB = "offloadAutoThresholdMB"
}

// MARK: - Helpers

/// Dropbox パスの正規化（先頭スラッシュ付与・末尾スラッシュ除去）。
/// 通常設定・Debug セクション・エンジン（夜間自動実行）で共用するため internal（UIKit 非依存）。
public func backupNormalizedPath(_ path: String) -> String {
    var s = path.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { return "/" }
    if !s.hasPrefix("/") { s = "/" + s }
    while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
    return s
}