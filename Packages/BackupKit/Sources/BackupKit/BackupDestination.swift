import Foundation

/// バックアップ先の選択肢。
/// `@AppStorage` で永続化するため `String` raw value を使用する。
public enum BackupDestination: String, CaseIterable {
    case disabled
    case dropbox
}
