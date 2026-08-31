import Darwin
import Foundation

/// **Swift の trap（fatalError / precondition / 配列外 / SwiftData）で落ちたことを、端末のログに残す。**
///
/// ## なぜ必要か（実機ログ・8/31 朝）
/// 「今朝、使ってみたら落ちまくり」の診断ログには、クラッシュの行が **1 本もなかった**。
/// 理由は 2 つあり、どちらも「落ちた記録が残らない」形だった:
/// 1. `NSSetUncaughtExceptionHandler` は **ObjC 例外しか通らない**。Swift の trap は素通り。
/// 2. その handler すら `append`（`queue.async`）で書いていたため、書く前にプロセスが終わっていた。
///
/// 記録が無いと「4 回落ちた」以上のことが何も分からない——原因の切り分けが**次のログ待ち**になる。
///
/// ## 仕組みと制約
/// 致命シグナル（SIGABRT/SIGILL/SIGTRAP/SIGSEGV/SIGBUS/SIGFPE）にハンドラを掛け、
/// **async-signal-safe な `write(2)` だけ**でログへ 1 行書き、既定ハンドラへ戻して落とす
/// （標準のクラッシュレポートは従来どおり Organizer に残る）。
///
/// ⚠️ ハンドラ内では**アロケートしない・Swift ランタイムを呼ばない**。そのため
/// - ファイルは install 時に開いた fd を使い回す
/// - 出力する文字列は install 時に C バッファへ作り置きする
/// - 時刻は付けない（`strftime` は signal-safe ではない。行の位置と次の launch 行で足りる）
enum CrashSignals {

    /// 直前の操作（`Diagnostics.breadcrumb`）。固定長・ゼロ終端。
    private static let breadcrumbCapacity = 192
    nonisolated(unsafe) private static var breadcrumb =
        UnsafeMutablePointer<CChar>.allocate(capacity: breadcrumbCapacity)

    /// シグナル番号 → 書き出す前置き（install 時に作り置き）。
    nonisolated(unsafe) private static var messages =
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)

    /// 追記先の fd（install 時に開きっぱなしにする）。
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var installed = false

    private static let handled: [Int32] = [SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE]

    static func install(fileURL: URL) {
        guard !installed else { return }
        installed = true

        breadcrumb.initialize(repeating: 0, count: breadcrumbCapacity)
        messages.initialize(repeating: nil, count: 32)
        setBreadcrumb("(なし)")

        fd = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard fd >= 0 else { return }

        for sig in handled {
            guard sig >= 0, sig < 32 else { continue }
            messages[Int(sig)] = makeCString(
                "\nCRASH \(name(of: sig)) — Swift の trap かシグナルで強制終了（直前の操作: ")
            signal(sig, crashSignalHandler)
        }
    }

    /// 直前の操作を覚える。**ここでだけ**アロケート・コピーする（ハンドラ内では読むだけ）。
    static func setBreadcrumb(_ label: String) {
        label.withCString { src in
            _ = strlcpy(breadcrumb, src, breadcrumbCapacity)
        }
    }

    /// テスト用: ハンドラと同じ書き出しを、プロセスを落とさずに行う。
    static func writeCrashLineForTesting(_ sig: Int32) { writeCrashLine(sig) }

    /// テスト用: 別のファイルへ張り直す（シグナルの捕捉は行わない＝テストを落とさない）。
    static func installForTesting(fileURL: URL) {
        if fd >= 0 { close(fd) }
        installed = false
        breadcrumb.initialize(repeating: 0, count: breadcrumbCapacity)
        messages.initialize(repeating: nil, count: 32)
        fd = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        for sig in handled where sig >= 0 && sig < 32 {
            messages[Int(sig)] = makeCString(
                "\nCRASH \(name(of: sig)) — Swift の trap かシグナルで強制終了（直前の操作: ")
        }
        installed = true
    }

    // MARK: - signal-safe な書き出し

    /// ⚠️ ここから下は**シグナルハンドラ文脈**で走る。`write` 以外を増やさないこと。
    fileprivate static func writeCrashLine(_ sig: Int32) {
        guard fd >= 0, sig >= 0, sig < 32 else { return }
        if let prefix = messages[Int(sig)] { _ = write(fd, prefix, strlen(prefix)) }
        _ = write(fd, breadcrumb, strlen(breadcrumb))
        _ = write(fd, ")\n", 2)
    }

    private static func name(of sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"   // Swift の fatalError / precondition はこれ
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGFPE: return "SIGFPE"
        default: return "SIGNAL \(sig)"
        }
    }

    private static func makeCString(_ text: String) -> UnsafeMutablePointer<CChar> {
        let bytes = Array(text.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        return buffer
    }
}

/// トップレベル関数（キャプチャ無し＝C 関数ポインタとして渡せる）。
/// 記録したら**既定のハンドラへ戻して落とす**——標準のクラッシュレポートを潰さないため。
private func crashSignalHandler(_ sig: Int32) {
    CrashSignals.writeCrashLine(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
