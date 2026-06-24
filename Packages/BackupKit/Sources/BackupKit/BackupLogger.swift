import Foundation
import MosaicSupport

/// BackupKit 内部ロガー。実体は共通の `LogChannel`（MosaicSupport）に委譲する。
/// 失敗は常に記録する。
enum BackupLogger {
    private static let channel = LogChannel(
        subsystem: "com.mosaicphotos.BackupKit", label: "BackupKit")

    static func error(_ message: @autoclosure () -> String) { channel.error(message()) }
}
