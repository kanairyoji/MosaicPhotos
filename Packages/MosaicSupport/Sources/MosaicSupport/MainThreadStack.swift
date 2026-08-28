import Foundation

/// ハング中の**メインスレッドの呼び出しスタック**をその場で採取する（実機・自前）。
///
/// ⚠️ なぜ要るか（実機 diagnostics-56）: 前面で 78 秒、メインが約 95% 停止した
/// （ping 到達数が 10 秒あたり 46〜49 回 → 2〜4 回）。ところが**その間ログは一切出ない**
/// ——ログを書くのもメインの仕事だからで、ウォッチドッグが残せるのは「いつ・何秒」だけ。
/// 「直前のログ行を疑え」も、背景処理が同時に何本も動いている状況では因果を特定できない。
///
/// ADR-106 で MetricKit（`MXHangDiagnostic`）を入れたが、**届くのは 1 日 1 回まで**で、
/// 前面ハング 9 件を含む 5.5 時間のログに `HANG-DIAG:` は 1 行も無かった。原因究明が
/// OS の配信タイミング待ちになる。そこで、ハングが**続いている最中に**自分で採取する。
///
/// 安全性の設計:
/// - `thread_suspend` から `thread_resume` までの区間で**一切アロケートしない**。
///   メインが malloc のロックを持ったまま止まっている可能性があり、その間に確保すると
///   デッドロックする。読み出し先は起動時に確保した固定バッファのみ。
/// - メモリ読み出しは `vm_read_overwrite`（失敗はエラーを返す）で行う。壊れたフレームポインタを
///   直接 deref してクラッシュさせない。
/// - シンボル化（`dladdr` / デマングル）は **resume した後**に行う。
/// - 実機 arm64 のみ。シミュレータ・macOS では何もしない（空を返す）。
public enum MainThreadStack {

    /// 採取するフレーム数の上限（バッファの確保サイズ）。
    ///
    /// ⚠️ 深く採る（実機 diagnostics-60）。16 フレームでは
    /// `pread → sqlite3 → CoreData` のようなシステム側の連なりで枠を使い切り、
    /// **アプリのフレームに 1 つも届かなかった**＝誰が呼んだのか分からなかった。
    public static let capacity = 96

#if os(iOS) && arch(arm64) && !targetEnvironment(simulator)

    /// メインスレッドの送信権。**メインスレッド上で** `install()` して得る。
    private nonisolated(unsafe) static var mainThreadPort: mach_port_t = 0
    /// 採取用の固定バッファ（suspend 中にアロケートしないため、起動時に確保して使い回す）。
    private nonisolated(unsafe) static let pcBuffer =
        UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
    private nonisolated(unsafe) static let stateBuffer =
        UnsafeMutablePointer<natural_t>.allocate(capacity: stateWordCount)
    /// 同時採取を防ぐ（2 本が同じバッファを踏むのを避ける）。
    private nonisolated(unsafe) static let lock = NSLock()

    /// `arm_thread_state64_t` を 32bit 語で数えた長さ（ARM_THREAD_STATE64_COUNT 相当）。
    /// マクロは Swift へ取り込まれないので実サイズから計算する。
    private static var stateWordCount: Int {
        MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
    }

    /// レジスタ配列（x0…x28, fp, lr, sp, pc, cpsr）の添字。
    private static let fpIndex = 29, lrIndex = 30, pcIndex = 32

    /// **メインスレッド上で 1 回だけ**呼ぶ（`Diagnostics.install()` から）。
    public static func install() {
        guard Thread.isMainThread, mainThreadPort == 0 else { return }
        mainThreadPort = mach_thread_self()
    }

    /// いまメインスレッドが実行している位置のスタックを返す（新しい順・シンボル化済み）。
    /// 採取できないときは空。**メイン以外のスレッドから呼ぶこと**。
    public static func capture(limit: Int = capacity) -> [String] {
        let port = mainThreadPort
        guard port != 0, !Thread.isMainThread else { return [] }
        guard lock.try() else { return [] }
        defer { lock.unlock() }

        let wanted = min(limit, capacity)
        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        let count = readFrames(port: port, limit: wanted)   // ← この中でアロケートしない
        thread_resume(port)
        guard count > 0 else { return [] }

        return (0..<count).map { symbolicate(pcBuffer[$0], index: $0) }
    }

    /// suspend 中に走る部分。**アロケート禁止**（固定バッファのみ／戻り値は Int）。
    private static func readFrames(port: mach_port_t, limit: Int) -> Int {
        var stateCount = mach_msg_type_number_t(stateWordCount)
        guard thread_get_state(port, ARM_THREAD_STATE64, stateBuffer, &stateCount) == KERN_SUCCESS
        else { return 0 }

        let regs = UnsafeRawPointer(stateBuffer).assumingMemoryBound(to: UInt64.self)
        var frames = 0
        func push(_ value: UInt64) {
            guard frames < limit, value != 0 else { return }
            pcBuffer[frames] = value
            frames += 1
        }
        push(strip(regs[pcIndex]))    // いま実行中の位置
        push(strip(regs[lrIndex]))    // 呼び出し元（まだフレームを積んでいない場合に効く）

        // arm64 のフレーム鎖: [fp] = 呼び出し元の fp / [fp+8] = 戻り先。
        var fp = regs[fpIndex]
        while frames < limit, fp != 0, fp % 8 == 0 {
            var pair: (UInt64, UInt64) = (0, 0)
            var read: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) { destination -> Bool in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16,
                                  vm_address_t(UInt(bitPattern: destination)), &read) == KERN_SUCCESS
            }
            guard ok, read == 16 else { break }
            let next = pair.0, returnAddress = strip(pair.1)
            guard returnAddress != 0 else { break }
            push(returnAddress)
            guard next > fp else { break }   // 単調増加でなければ鎖が壊れている＝打ち切る
            fp = next
        }
        return frames
    }

    /// ポインタ認証（arm64e）の署名ビットを落とす。plain arm64 では無害。
    private static func strip(_ address: UInt64) -> UInt64 { address & 0x0000_000F_FFFF_FFFF }

    /// `dladdr` でイメージ名＋シンボルへ落とす（resume 後に呼ぶ＝アロケートしてよい）。
    private static func symbolicate(_ address: UInt64, index: Int) -> String {
        let number = String(format: "%2d", index)
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else {
            return "\(number) 0x\(String(address, radix: 16))"
        }
        var info = Dl_info()
        guard dladdr(pointer, &info) != 0 else {
            return "\(number) 0x\(String(address, radix: 16))"
        }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let name = info.dli_sname.map({ String(cString: $0) }) else {
            let base = UInt(bitPattern: info.dli_fbase)
            return "\(number) \(image) +\(UInt(address) &- base)"
        }
        let offset = UInt(address) &- UInt(bitPattern: info.dli_saddr)
        return "\(number) \(image) \(demangled(name))\(offset > 0 ? " +\(offset)" : "")"
    }

    /// Swift のマングル名を読める形へ（`swift_demangle` があれば使う・無ければ素のまま）。
    private static func demangled(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s"), let demangle = swiftDemangle
        else { return symbol }
        guard let result = symbol.withCString({ demangle($0, strlen($0), nil, nil, 0) })
        else { return symbol }
        defer { free(result) }
        return String(cString: result)
    }

    private typealias SwiftDemangle =
        @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                        UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    private nonisolated(unsafe) static let swiftDemangle: SwiftDemangle? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        else { return nil }
        return unsafeBitCast(symbol, to: SwiftDemangle.self)
    }()

#else

    /// 実機 arm64 以外では何もしない（シミュレータ・macOS テスト）。
    public static func install() {}
    public static func capture(limit: Int = 96) -> [String] { [] }

#endif
}
