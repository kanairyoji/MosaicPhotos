import Foundation

/// バックアップ実行ログの 1 行。`BackupEngine.log` に蓄積し Debug セクションで表示する。
public struct BackupLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let time: String
    public let message: String

    init(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        self.time    = f.string(from: Date())
        self.message = message
    }
}
