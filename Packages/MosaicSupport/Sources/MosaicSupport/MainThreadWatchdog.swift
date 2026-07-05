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

    /// 即時ログするハングしきい値（ms）。
    public var hangImmediateMs: Double = 500

    private init() {}

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
        let t0 = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1_000_000
            self.record(ms)
        }
    }

    private func record(_ ms: Double) {
        lock.lock()
        pings += 1
        if ms > 83 { over83 += 1 }
        if ms > 250 { over250 += 1 }
        if ms > maxMs { maxMs = ms }
        lock.unlock()
        if ms > hangImmediateMs {
            // 呼び出しスタックは取れないが、直前の PERF/mark 行と突き合わせて犯人を絞る。
            DiagnosticsLog.shared.append(String(format: "PERF hang main=%.0fms", ms))
        }
    }

    /// 集計サマリを返してリセットする（何も起きていなければ nil）。定期フラッシュから呼ぶ。
    public func flushSummary() -> String? {
        lock.lock()
        defer { pings = 0; over83 = 0; over250 = 0; maxMs = 0; lock.unlock() }
        guard pings > 0 else { return nil }
        return String(format: "main: pings=%d >83ms=%d >250ms=%d max=%.0fms",
                      pings, over83, over250, maxMs)
    }
}
