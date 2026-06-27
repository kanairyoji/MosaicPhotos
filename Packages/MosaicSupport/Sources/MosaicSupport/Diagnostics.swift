import Darwin
import Foundation
import os

/// 端末上でも読めるロールリングのファイルログ。`LogChannel` の出力（error は常時、info/verbose は DEBUG）と
/// `Diagnostics`（未捕捉例外・メモリ圧迫）をここへ追記し、Developer Options で閲覧/共有できるようにする。
/// Mac の Console が無くても実機で何が起きたか確認できるのが目的。
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    private let queue = DispatchQueue(label: "com.mosaicphotos.diagnostics")
    private let fileURL: URL
    /// この2倍を超えたら末尾 maxBytes に切り詰める（ログの肥大を防ぐ）。
    private let maxBytes = 256 * 1024

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("diagnostics.log")
    }

    /// 1 行追記（タイムスタンプ付き）。複数スレッドから呼ばれるため直列キューで処理する。
    public func append(_ line: String) {
        queue.async { [fileURL, maxBytes] in
            let stamped = "\(Self.timestamp()) \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
            // サイズ上限：大きくなりすぎたら末尾だけ残す。
            if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int,
               size > maxBytes * 2, let all = try? Data(contentsOf: fileURL) {
                try? Data(all.suffix(maxBytes)).write(to: fileURL)
            }
        }
    }

    /// 直近のログ全文（Developer Options 表示用）。
    public func recentText() -> String {
        queue.sync { (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "" }
    }

    public func clear() {
        queue.sync { try? Data().write(to: fileURL) }
    }

    /// 共有用のファイル URL。
    public var url: URL { fileURL }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return f
    }()
    private static func timestamp() -> String { formatter.string(from: Date()) }
}

/// 現在のアプリのメモリ使用量（phys_footprint, MB）。取得できなければ nil。
public func currentMemoryFootprintMB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return nil }
    return Double(info.phys_footprint) / 1024.0 / 1024.0
}

/// 起動時に一度だけ呼び、未捕捉例外とメモリ圧迫を診断ログへ記録する。
public enum Diagnostics {
    private static let log = Logger(subsystem: "com.mosaicphotos.Diagnostics", category: "diagnostics")
    private static var memorySource: DispatchSourceMemoryPressure?

    public static func install() {
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        DiagnosticsLog.shared.append("=== launch (footprint=\(mb)) ===")

        // ObjC 未捕捉例外（unrecognized selector / KVO / CoreData など）を記録してから落ちる。
        // ※ Swift の fatalError / precondition / SwiftData の trap はこのハンドラを通らない
        //   （それらは Xcode/Organizer の標準クラッシュログに出る）。
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(24).joined(separator: "\n")
            let line = "UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "")\n\(stack)"
            DiagnosticsLog.shared.append(line)
            Logger(subsystem: "com.mosaicphotos.Diagnostics", category: "crash").error("\(line, privacy: .public)")
        }

        // メモリ圧迫（warning/critical）を使用量つきで記録（実機の jetsam 前兆を可視化）。
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler {
            let level = source.data.contains(.critical) ? "CRITICAL" : "warning"
            let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
            DiagnosticsLog.shared.append("MEMORY PRESSURE: \(level) (footprint=\(mb))")
            log.error("memory pressure: \(level, privacy: .public)")
        }
        source.resume()
        memorySource = source
    }
}
