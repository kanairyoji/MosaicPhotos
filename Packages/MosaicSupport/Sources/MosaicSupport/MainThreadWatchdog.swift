import Foundation

/// メインスレッドの応答性センサー（実機のパフォーマンス分析用）。
///
/// 背景スレッドから一定間隔でメインスレッドへ ping（`DispatchQueue.main.async`）を送り、
/// **スケジューリング遅延**＝「メインが他の仕事で塞がっていた時間」を実測する。
/// 「フォアグラウンドで重い処理を動かさない」原則が守られているかを、体感でなく数値で検証できる。
///
/// - 遅延 > `hangImmediateMs`（既定 500ms）は即時に 1 行ログ（`PERF hang`）。
/// - それ以下はカウンタ集計し、`flushSummary()`（PerfTrace の定期フラッシュ）で
///   `pings / >83ms / >250ms / max` を 1 行に出す。83ms ≒ 5 フレーム（60fps）＝目に見える引っかかり。
/// - `PerfTrace.isEnabled` と連動して start/stop する（無効時のオーバーヘッドはゼロ）。
public final class MainThreadWatchdog: @unchecked Sendable {
    public static let shared = MainThreadWatchdog()

    private let queue = DispatchQueue(label: "com.mosaicphotos.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let lock = NSLock()
    private var pings = 0
    private var over83 = 0
    private var over250 = 0
    private var maxMs: Double = 0
    /// 背面で観測した停止の回数（ユーザーには見えないので本体の集計には混ぜない）。
    private var backgroundStalls = 0
    /// アプリが前面でアクティブか（`BackgroundYield.isAppActive` が同期する）。
    /// ⚠️ **背面の「ハング」は計測ノイズ**（ADR-82）。iOS はアプリが背面にいる間メインランループを
    /// 絞り、必要なら中断する。`ProcessSuspension` は**正式な中断**しか捉えられないため、
    /// 単なる throttle は「メインが 28 秒ブロック」として記録され、実機ログを読み誤らせていた
    /// （実測 diagnostics-32: 39 件のうち 31 件が背面＝ユーザーには一切見えない）。
    /// 体感に効くのは前面の停止だけなので、そちらだけを数値として残す。
    private var appActive = true

    /// 未返答の ping の送信時刻（ns・0=なし）。queue 上でのみ触る。
    private var outstandingSinceNs: UInt64 = 0
    /// ping 送信時の中断世代。返答時に変わっていたら、その待ち時間は**プロセス中断**であって
    /// メインスレッドのブロックではない（実機ログで「メインが 29 分ブロック」と誤報していた）。
    private var outstandingEpoch = 0
    /// このハングの「開始」を既に記録したか（1 ハングにつき 1 回だけ hang.begin を出す）。
    private var hangBeginReported = false

    /// 即時ログするハングしきい値（ms）。
    public var hangImmediateMs: Double = 500
    /// ハング「開始」を疑って即時記録するしきい値（ms）。解消を待たずに時刻を残すことで、
    /// 「どのログ行の直後にメインが止まったか」をログの時系列で特定できるようにする。
    public var hangBeginSuspectMs: Double = 1000
    /// メインスレッドのスタックを採取するしきい値（ms）。**止まっている最中に**採る
    /// （終わってからでは犯人が居ない）。長いハングだけに絞ってオーバーヘッドを避ける。
    public var stackCaptureMs: Double = 2000
    /// スタック採取の間隔（ns）。長い停止が続く間も一定間隔で採り直し、「同じ場所で止まり続けて
    /// いるのか、別の処理が数珠つなぎなのか」を読めるようにする。
    public var stackCaptureIntervalNs: UInt64 = 15_000_000_000
    /// 直近に採取した時刻（ns・0=未採取）。queue 上でのみ触る。
    private var lastStackCaptureNs: UInt64 = 0

    private init() {}

    /// 前面/背面を伝える（`BackgroundYield.isAppActive` から自動で同期される）。
    /// `nonisolated`：ウォッチドッグは MainActor 外（専用 queue・main.async クロージャ）から
    /// この値を読むため、ロック保護の素の状態として持つ。
    public func setAppActive(_ active: Bool) {
        lock.lock()
        if active, !appActive { lastBecameActiveNs = DispatchTime.now().uptimeNanoseconds }
        appActive = active
        lock.unlock()
    }

    /// 直近に**前面へ復帰した**時刻（ns）。これより前に送った ping は前面のハングとして数えない。
    ///
    /// ⚠️ 「返答時に前面かどうか」だけでは足りない（ADR-97）。背面で送った ping が復帰の瞬間に
    /// 返ると、中断/throttle の待ち時間がまるごと「前面のハング」として記録される。実機
    /// diagnostics-43 では、重い処理が**一つも走っていない**復帰
    ///（`prewarm cancelled at 0/314`・`model load skipped` ×4・`infer=0ms`）で
    /// `hang main=11041ms` が出ていた。`ProcessSuspension` は**正式な中断**しか捉えられず、
    /// 復帰前後の throttle はすり抜けるため、前面区間に完全に収まる ping だけを採用する。
    private var lastBecameActiveNs: UInt64 = 0

    private var isAppActiveLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return appActive
    }

    /// この ping は前面へ復帰する**前**に送られたか（＝前面区間に収まっていない）。
    private func startedBeforeBecomingActive(_ startedNs: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return startedNs != 0 && startedNs < lastBecameActiveNs
    }

    public func start(interval: TimeInterval = 0.2) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
            t.setEventHandler { [weak self] in self?.ping() }
            t.resume()
            timer = t
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func ping() {
        // 前回の ping が未返答＝メインが塞がっている。新しい ping は積まず（解消時の
        // ラダー状ログを防ぐ）、しきい値を超えたら「開始」を一度だけ即時記録する。
        if outstandingSinceNs != 0 {
            // 中断を跨いだ待ちは「ブロック」ではないので報告しない（誤報の主因だった）。
            if ProcessSuspension.didSuspend(since: outstandingEpoch) { return }
            // 背面の停止は OS による throttle＝体感に無関係なので「開始」も報告しない。
            guard isAppActiveLocked else { return }
            // 復帰をまたいだ ping も同様に報告しない（`record` と同じ判定・ADR-97）。
            guard !startedBeforeBecomingActive(outstandingSinceNs) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let age = Double(now &- outstandingSinceNs) / 1_000_000
            if age > hangBeginSuspectMs, !hangBeginReported {
                hangBeginReported = true
                DiagnosticsLog.shared.append(String(format: "PERF hang.begin main blocked ≥%.0fms — suspect the processing at the previous log line", age))
            }
            // ⚠️ 犯人はここでしか捕まえられない。ハング中はメインが止まっている＝ログも
            // 進捗も出ないので、「止まっている今」スタックを採る（実機 diagnostics-56 では
            // 78 秒の停止中、hang 行以外に手がかりが 1 行も無かった）。
            if Self.shouldCaptureStack(ageMs: age, threshold: stackCaptureMs,
                                       lastCaptureNs: lastStackCaptureNs, nowNs: now,
                                       intervalNs: stackCaptureIntervalNs) {
                lastStackCaptureNs = now
                captureMainStack(ageMs: age)
            }
            return
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        let epoch = ProcessSuspension.epoch
        outstandingSinceNs = t0
        outstandingEpoch = epoch
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            // 送信〜返答の間に中断があったサンプルは、待ち時間の実体が suspend なので捨てる。
            if !ProcessSuspension.didSuspend(since: epoch) { self.record(ms, startedNs: t0) }
            self.queue.async {
                self.outstandingSinceNs = 0
                self.hangBeginReported = false
                self.lastStackCaptureNs = 0   // 解消した＝次のハングは 1 枚目からすぐ採る
            }
        }
    }

    /// `internal`：テストから直接サンプルを流し込んで前面/背面の分類を検証するため。
    /// - Parameter startedNs: ping の送信時刻。`0` なら判定に使わない（テストの簡便のため）。
    func record(_ ms: Double, startedNs: UInt64 = 0) {
        lock.lock()
        // 背面のサンプルは本体の集計に混ぜない（max が OS の throttle で汚染され、
        // 前面の実力＝体感が読めなくなる）。件数だけ別に数えて記録は残す。
        guard appActive else {
            if ms > hangImmediateMs { backgroundStalls += 1 }
            lock.unlock()
            return
        }
        // ⚠️ 前面区間に**完全に収まる** ping だけを採用する（ADR-97）。背面で送った ping が
        //    復帰の瞬間に返ると「返答時は前面」なので上のガードを通ってしまい、中断/throttle の
        //    待ちが 10 秒級の「前面ハング」として記録される（実機 diagnostics-40〜43 の大物は
        //    ほぼこれで、実際には重い処理が一つも走っていなかった）。
        if startedNs != 0, startedNs < lastBecameActiveNs {
            if ms > hangImmediateMs { backgroundStalls += 1 }
            lock.unlock()
            return
        }
        pings += 1
        if ms > 83 { over83 += 1 }
        if ms > 250 { over250 += 1 }
        if ms > maxMs { maxMs = ms }
        lock.unlock()
        if ms > hangImmediateMs {
            // 呼び出しスタックは取れないが、直前の PERF/mark 行と突き合わせて犯人を絞る。
            DiagnosticsLog.shared.append(String(format: "PERF hang main=%.0fms (foreground)", ms))
        }
    }

    /// スタックを採るか（純ロジック・テスト対象）。
    ///
    /// - 短い引っかかりでは採らない（`threshold`）。採取はメインを一瞬 suspend するので、
    ///   体感に出る長さの停止だけに絞る。
    /// - 停止が続く間は `intervalNs` ごとに採り直す。**1 回で終わらせない**のが要点で、
    ///   「同じ場所で止まり続けている」のか「別の重い処理が数珠つなぎ」なのかは、
    ///   時間をおいた 2 枚目以降を見ないと区別できない（実機 diagnostics-56 の 78 秒停止は
    ///   約 6 秒のハングが 5 回続いた形だった）。
    /// - `lastCaptureNs == 0`＝この停止ではまだ未採取なので、しきい値を超えたら即採る。
    static func shouldCaptureStack(ageMs: Double, threshold: Double,
                                   lastCaptureNs: UInt64, nowNs: UInt64,
                                   intervalNs: UInt64) -> Bool {
        guard ageMs > threshold else { return false }
        guard lastCaptureNs != 0 else { return true }
        guard nowNs > lastCaptureNs else { return false }
        return nowNs &- lastCaptureNs > intervalNs
    }

    /// 止まっているメインスレッドのスタックを診断ログへ落とす（`queue` 上から呼ぶ）。
    /// 採れない環境（シミュレータ・macOS）では `MainThreadStack` が空を返して何も出ない。
    private func captureMainStack(ageMs: Double) {
        let frames = Self.interestingFrames(MainThreadStack.capture())
        guard !frames.isEmpty else { return }
        DiagnosticsLog.shared.append(String(format: "PERF hang.stack main blocked ≥%.0fms — 呼び出しスタック（新しい順）", ageMs))
        for frame in frames { DiagnosticsLog.shared.append("PERF hang.stack   \(frame)") }
    }

    /// ログに出すフレームを選ぶ（純ロジック・テスト対象）。
    ///
    /// ⚠️ 全部出すと長すぎ、浅く採るとアプリに届かない（実機 diagnostics-60 では
    /// `pread → sqlite3 → CoreData` の連なりで 16 フレームを使い切り、**誰が呼んだのかが
    /// 1 つも分からなかった**）。深く採ったうえで、
    ///   - 先頭数フレーム（何で止まっているか＝システム側の待ち）
    ///   - **自アプリのフレーム**（誰が呼んだか）
    /// だけを残す。system 側の中間フレームは読み手の役に立たない。
    static func interestingFrames(_ frames: [String], topSystemFrames: Int = 4,
                                  maxAppFrames: Int = 14) -> [String] {
        guard !frames.isEmpty else { return [] }
        var out = Array(frames.prefix(topSystemFrames))
        var appFrames = 0
        for frame in frames.dropFirst(topSystemFrames) where !isSystemFrame(frame) {
            guard appFrames < maxAppFrames else { break }
            out.append(frame)
            appFrames += 1
        }
        return out
    }

    /// OS/ランタイム由来のフレームか（＝誰が呼んだかの手がかりにならない）。
    private static func isSystemFrame(_ frame: String) -> Bool {
        // 出力形式: "<番号> <イメージ名> <シンボル> +<オフセット>"
        let parts = frame.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return false }
        let image = String(parts[1])
        return systemImagePrefixes.contains { image.hasPrefix($0) }
    }

    private static let systemImagePrefixes = [
        "libsystem", "libsqlite3", "libobjc", "libdispatch", "libswift", "libc++", "libRPAC",
        "CoreData", "CoreFoundation", "Foundation", "SwiftUI", "UIKitCore", "UIKit",
        "QuartzCore", "CoreGraphics", "CoreImage", "Photos", "PhotosUI",
        "PhotoLibraryServices", "CoreML", "Vision", "Espresso", "Metal", "GraphicsServices",
    ]

    /// 集計サマリを返してリセットする（何も起きていなければ nil）。定期フラッシュから呼ぶ。
    /// 背面の停止は `bgStalls=N`（参考値）として別枠で出す。
    public func flushSummary() -> String? {
        lock.lock()
        defer { pings = 0; over83 = 0; over250 = 0; maxMs = 0; backgroundStalls = 0; lock.unlock() }
        guard pings > 0 || backgroundStalls > 0 else { return nil }
        let bg = backgroundStalls > 0 ? " bgStalls=\(backgroundStalls)" : ""
        guard pings > 0 else { return "main: (background)\(bg)" }
        return String(format: "main: pings=%d >83ms=%d >250ms=%d max=%.0fms",
                      pings, over83, over250, maxMs) + bg
    }
}
