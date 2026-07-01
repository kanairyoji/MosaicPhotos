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
        // クリア後もどのビルドで消したか分かるよう、先頭にバージョン行を残す。
        append("=== cleared — MosaicPhotos \(appVersionLine()) ===")
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

/// メモリ圧迫の段階。`DispatchSource` の warning / critical に対応する。
public enum MemoryPressureLevel: String, Sendable {
    case warning
    case critical
}

/// メモリ圧迫イベント 1 件の記録（Developer Options 表示用）。
public struct MemoryPressureEvent: Sendable {
    public let date: Date
    public let level: MemoryPressureLevel
    public let footprintMB: Double?
    public init(date: Date, level: MemoryPressureLevel, footprintMB: Double?) {
        self.date = date
        self.level = level
        self.footprintMB = footprintMB
    }
}

/// メモリ圧迫の中枢。`Diagnostics` のメモリ圧迫ソースが warning/critical を `handle(_:)` に流し込み、
/// ここが (1) 圧迫フラグの設定（一定時間後に自動解除）、(2) 登録された**解放ハンドラ**の呼び出し、
/// (3) 診断ログへの記録、(4) Developer Options 表示用の履歴/回数の蓄積、を一括で行う。
/// 背景の重い処理（CLIP 埋め込み等）は `isUnderPressure` を見て一時停止し、画像キャッシュは
/// `register(_:)` した解放ハンドラ経由で warning=縮小 / critical=全消去する。
public final class MemoryPressureMonitor: @unchecked Sendable {
    public static let shared = MemoryPressureMonitor()
    private let lock = NSLock()
    private var _underPressure = false
    /// 圧迫フラグを下ろす予定の世代。連続イベントで延長するために使う。
    private var generation = 0

    /// 圧迫時に呼ぶ解放ハンドラ（トークンで解除可能）。
    private var handlers: [Int: @Sendable (MemoryPressureLevel) -> Void] = [:]
    private var nextToken = 0

    /// Developer Options 表示用：直近の圧迫イベント（古い順・末尾が最新）と累計回数。
    private var events: [MemoryPressureEvent] = []
    private var _totalCount = 0
    private let maxEvents = 20

    private init() {}

    public var isUnderPressure: Bool {
        lock.lock(); defer { lock.unlock() }
        return _underPressure
    }

    /// 累計の圧迫イベント数。
    public var totalPressureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalCount
    }

    /// 直近の圧迫イベント（最新が先頭）。
    public func recentEvents() -> [MemoryPressureEvent] {
        lock.lock(); defer { lock.unlock() }
        return events.reversed()
    }

    /// 圧迫時に呼ばれる解放ハンドラを登録する。戻り値のトークンで解除できる。
    /// ハンドラは**バックグラウンドスレッドから呼ばれ得る**ためスレッドセーフに実装すること。
    @discardableResult
    public func register(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) -> Int {
        lock.lock()
        let token = nextToken
        nextToken += 1
        handlers[token] = handler
        lock.unlock()
        return token
    }

    public func unregister(_ token: Int) {
        lock.lock(); handlers[token] = nil; lock.unlock()
    }

    /// メモリ圧迫を受けて、圧迫フラグ設定・履歴記録・解放ハンドラ呼び出し・診断ログ追記を行う。
    /// `autoClearAfter` 秒後に圧迫フラグを自動で下ろす（その間に再発すれば延長）。
    public func handle(_ level: MemoryPressureLevel, autoClearAfter seconds: TimeInterval = 20) {
        let footprint = currentMemoryFootprintMB()
        lock.lock()
        _underPressure = true
        generation += 1
        let gen = generation
        _totalCount += 1
        events.append(MemoryPressureEvent(date: Date(), level: level, footprintMB: footprint))
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        let snapshot = Array(handlers.values)
        lock.unlock()

        // 詳細ログ：レベル・フットプリント・端末 RAM・解放ハンドラ数。実機で切り分けられるように残す。
        let fp = footprint.map { String(format: "%.0fMB", $0) } ?? "?"
        let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1024 / 1024 / 1024
        DiagnosticsLog.shared.append(
            "MEMORY PRESSURE: \(level.rawValue.uppercased()) "
            + "(footprint=\(fp), deviceRAM=\(String(format: "%.1fGB", ramGB)), handlers=\(snapshot.count))")

        // 登録された解放処理（画像キャッシュの縮小/全消去など）を実行してメモリを返す。
        for h in snapshot { h(level) }

        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            lock.lock()
            if generation == gen { _underPressure = false }   // 後続イベントが無ければ解除
            lock.unlock()
        }
    }

    /// 後方互換：レベル不明の圧迫として warning 扱いで `handle(_:)` する。
    func markPressure(autoClearAfter seconds: TimeInterval = 20) {
        handle(.warning, autoClearAfter: seconds)
    }
}

/// 診断ログに載せるビルド識別。アプリ版（CFBundleShortVersionString）＋ビルド番号
/// （CFBundleVersion）に加え、**実行ファイルの更新日時＝ビルド日時**を付ける。ビルド日時は
/// 毎ビルドで変わるため、アプリ版が同じでもどのビルドのログか判別できる。
public func appVersionLine() -> String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    var built = "?"
    if let url = Bundle.main.executableURL,
       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
       let date = attrs[.modificationDate] as? Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        built = f.string(from: date)
    }
    return "v\(short) (build \(build)) · built \(built)"
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

    /// 起動・主要フェーズの計測マーク。現在のメモリ使用量つきで診断ログへ 1 行追記する。
    /// 起動チューニングの Before/After を実機の診断ログで確認するために使う（低頻度・軽量）。
    public static func mark(_ label: String) {
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        DiagnosticsLog.shared.append("MARK \(label) (footprint=\(mb))")
    }

    public static func install() {
        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
        DiagnosticsLog.shared.append("=== launch — MosaicPhotos \(appVersionLine()) (footprint=\(mb)) ===")

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
            let level: MemoryPressureLevel = source.data.contains(.critical) ? .critical : .warning
            log.error("memory pressure: \(level.rawValue, privacy: .public)")
            // 記録・解放ハンドラ呼び出し・診断ログ・履歴は MemoryPressureMonitor に集約する。
            // 背景の重い処理（CLIP 埋め込み）は isUnderPressure を見て自動停止、
            // 画像キャッシュは登録ハンドラ経由で warning=縮小 / critical=全消去される（jetsam 回避）。
            MemoryPressureMonitor.shared.handle(level)
        }
        source.resume()
        memorySource = source
    }
}
