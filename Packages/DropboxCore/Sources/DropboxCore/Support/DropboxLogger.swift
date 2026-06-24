#if canImport(UIKit)
import Foundation
import MosaicSupport

/// DropboxKit internal logger. 実体は共通の `LogChannel`（MosaicSupport）に委譲する。
///
/// - `verbose(_:)` — compiled out in Release; high-frequency diagnostics.
/// - `info(_:)`    — compiled out in Release; lifecycle events.
/// - `error(_:)`   — always compiled in; genuine failures.
enum DropboxLogger {
    private static let channel = LogChannel(
        subsystem: "com.mosaicphotos.DropboxKit", label: "DropboxKit")

    static func verbose(_ message: @autoclosure () -> String) { channel.verbose(message()) }
    static func info(_ message: @autoclosure () -> String) { channel.info(message()) }
    static func error(_ message: @autoclosure () -> String) { channel.error(message()) }
}
#endif
