import Foundation
import os

/// パッケージ横断の共通ロギング。subsystem / ラベルを与えて各パッケージが自分の
/// チャンネルを作る。`DropboxLogger` / `BackupLogger` 等の重複していた os.log + print +
/// DEBUG ゲートのパターンをここに集約する。
///
/// - `verbose` / `info` — DEBUG ビルドのみ。高頻度・ライフサイクル診断用。
/// - `error` — 常にコンパイルされる。実際の失敗・想定外状態用。
public struct LogChannel: Sendable {
    /// `verbose` / `info` を実行時に抑制するための UserDefaults キー（設定の Debug セクション用）。
    /// キー未設定時は ON（既定）。`error` は対象外で常に記録する。
    public static let verboseLoggingKey = "debug.verboseLogging"

    /// 既定 ON。キーが明示的に false のときだけ抑制する。
    static var verboseEnabled: Bool {
        let ud = UserDefaults.standard
        return ud.object(forKey: verboseLoggingKey) == nil ? true : ud.bool(forKey: verboseLoggingKey)
    }

    private let label: String

#if DEBUG
    private let verboseLog: Logger
    private let infoLog: Logger
#endif
    private let errorLog: Logger

    /// - Parameters:
    ///   - subsystem: os.log のサブシステム（例 "com.mosaicphotos.DropboxKit"）。
    ///   - label: print プレフィックス（例 "DropboxKit"）。
    public init(subsystem: String, label: String) {
        self.label = label
#if DEBUG
        verboseLog = Logger(subsystem: subsystem, category: "verbose")
        infoLog = Logger(subsystem: subsystem, category: "info")
#endif
        errorLog = Logger(subsystem: subsystem, category: "error")
    }

    /// 高頻度の診断メッセージ。Release ではコンパイルアウト、DEBUG でも設定で抑制可能。
    public func verbose(_ message: @autoclosure () -> String) {
#if DEBUG
        guard Self.verboseEnabled else { return }
        let msg = message()
        verboseLog.debug("\(msg, privacy: .public)")
        print("[\(label):verbose] \(msg)")
#endif
    }

    /// ライフサイクル / 読み込みイベント。Release ではコンパイルアウト、DEBUG でも設定で抑制可能。
    public func info(_ message: @autoclosure () -> String) {
#if DEBUG
        guard Self.verboseEnabled else { return }
        let msg = message()
        infoLog.info("\(msg, privacy: .public)")
        print("[\(label)] \(msg)")
#endif
    }

    /// 実際の失敗・想定外状態。常に記録する。
    public func error(_ message: @autoclosure () -> String) {
        let msg = message()
        errorLog.error("\(msg, privacy: .public)")
        print("[\(label)] ERROR: \(msg)")
    }
}
