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

    private init() {}

    /// 前面/背面を伝える（`BackgroundYield.isAppActive` から自動で同期される）。
    /// `nonisolated`：ウォッチドッグは MainActor 外（専用 queue・main.async クロージャ）から
    /// この値を読むため、ロック保護の素の状態として持つ。
    public func setAppActive(_ active: Bool) {
        lock.lock(); appActive = active; lock.unlock()
    }

    private var isAppActiveLocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return appActive
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
            let age = Double(DispatchTime.now().uptimeNanoseconds &- outstandingSinceNs) / 1_000_000
            if age > hangBeginSuspectMs, !hangBeginReported {
                hangBeginReported = true
                DiagnosticsLog.shared.append(String(format: "PERF hang.begin main blocked ≥%.0fms — suspect the processing at the previous log line", age))
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
            if !ProcessSuspension.didSuspend(since: epoch) { self.record(ms) }
            self.queue.async {
                self.outstandingSinceNs = 0
                self.hangBeginReported = false
            }
        }
    }

    /// `internal`：テストから直接サンプルを流し込んで前面/背面の分類を検証するため。
    func record(_ ms: Double) {
        lock.lock()
        // 背面のサンプルは本体の集計に混ぜない（max が OS の throttle で汚染され、
        // 前面の実力＝体感が読めなくなる）。件数だけ別に数えて記録は残す。
        guard appActive else {
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
