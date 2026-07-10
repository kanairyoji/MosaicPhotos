import Foundation

/// バックアップ進捗（アップロード済み localIdentifier 一覧）の UserDefaults 永続化。
/// `BackupEngine`（件数表示・クリア）と `BackupRunner`（実行中の追記）が共用する。
struct BackupProgressStore {

    private static let uploadedIDsKey = BackupSettingsKeys.uploadedLocalIDs

    /// アップロード済み ID 集合を読み込む。
    func loadUploadedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.uploadedIDsKey) ?? [])
    }

    /// アップロード済み ID 集合を保存する。
    func saveUploadedIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.uploadedIDsKey)
    }
}
