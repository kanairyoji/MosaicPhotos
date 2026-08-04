import Foundation
import os

/// `PerfTrace` の可変状態をまとめた箱。
///
/// ⚠️ 以前は `PerfTrace` の static var（`isEnabled` / `counters` / `flushTimer` / `pendingScreens`）が
/// **保護なしのグローバル可変状態**だった（`-strict-concurrency=complete` で 4 件警告・Swift 6 ではエラー）。
/// `counters` / `pendingScreens` は `lock` 経由だったが、`isEnabled` と `flushTimer` は素通しで、
/// 実際に複数スレッドから読み書きされていた。
///
/// `@unchecked Sendable` の根拠（不変条件）: 可変状態はすべて private・アクセスは必ず `lock` 経由・
/// 可変参照を外へ出さない・すべて同期メソッドなのでロックを `await` 越しに保持しない。
private final class PerfState: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool
    private var counters: [String: (count: Int, total: Double)] = [:]
    private var pendingScreens: [String: UInt64] = [:]
    private var flushTimer: DispatchSourceTimer?

    init(enabled: Bool) { self.enabled = enabled }

    /// 計測 API はすべてこれを先頭で読む。NSLock の非競合取得は数十 ns で、
    /// この後に続く文字列生成やログ書き込みに比べれば無視できる（「無効時はほぼ無コスト」は維持）。
    var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    func addCount(_ key: String, value: Double) {
        lock.lock(); defer { lock.unlock() }
        var entry = counters[key] ?? (0, 0)
        entry.count += 1
        entry.total += value
        counters[key] = entry
    }

    func drainCounters() -> [String: (count: Int, total: Double)] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = counters
        counters.removeAll()
        return snapshot
    }

    func beginScreen(_ name: String, at ns: UInt64) {
        lock.lock(); pendingScreens[name] = ns; lock.unlock()
    }

    func takeScreenStart(_ name: String) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return pendingScreens.removeValue(forKey: name)
    }

    /// タイマー未設定なら `make()` で作って保持する（既にあれば何もしない）。
    func installTimerIfNeeded(_ make: () -> DispatchSourceTimer) {
        lock.lock(); defer { lock.unlock() }
        guard flushTimer == nil else { return }
        let timer = make()
        flushTimer = timer
        timer.resume()
    }

    func cancelTimer() {
        lock.lock(); defer { lock.unlock() }
        flushTimer?.cancel()
        flushTimer = nil
    }
}

/// 重い経路（特に Dropbox の通信・キャッシュ）の所要時間と回数を計測するための軽量トレース。
///
/// 既定は無効（`isEnabled == false`）。無効の間は各 API が先頭で即 return するため、
/// 呼び出し側に計測コードを残してもオーバーヘッドは無視できる。これにより「どこを計測したか」を
/// コード上に残しつつ、必要なときだけ ON にして同じ計測を再現できる。
///
/// 有効化（ON/OFF）の方法は 2 通り:
///  1. コンパイルスイッチ: ビルド設定 OTHER_SWIFT_FLAGS に `-DMOSAIC_PERF` を足すと既定 ON。
///  2. 実行時フラグ: `PerfTrace.isEnabled = true`。実機では Developer Options のトグルから切替できる。
///
/// 出力先は 2 つ:
///  - os_signpost（Instruments の Points of Interest。Mac 接続時に時系列で可視化）
///  - DiagnosticsLog（端末内ログ。Mac なしで Developer Options から閲覧・共有できる）
public enum PerfTrace {
#if MOSAIC_PERF
    private static let state = PerfState(enabled: true)
#else
    private static let state = PerfState(enabled: false)
#endif

    /// 計測の ON/OFF。無効の間は各 API が先頭で即 return する。
    public static var isEnabled: Bool {
        get { state.isEnabled }
        set { state.setEnabled(newValue); updateSensors() }
    }

    private static let log = OSLog(subsystem: "com.mosaicphotos.perf", category: "PointsOfInterest")

    // MARK: - 常駐センサー（有効中のみ）: メインスレッド監視＋定期フラッシュ

    private static let flushQueue = DispatchQueue(label: "com.mosaicphotos.perf.flush", qos: .utility)

    /// ON: メインスレッド監視（MainThreadWatchdog）を開始し、10 秒ごとに
    /// 「footprint＋メイン応答性サマリ」「集計カウンタ」を診断ログへ書く。OFF: 停止。
    /// ※ 初期値では didSet が呼ばれないが、アプリ起動時に設定値を必ず代入するため実質常に反映される。
    private static func updateSensors() {
        if isEnabled {
            MainThreadWatchdog.shared.start()
            flushQueue.async {
                state.installTimerIfNeeded {
                    let t = DispatchSource.makeTimerSource(queue: flushQueue)
                    t.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
                    t.setEventHandler {
                        let mb = currentMemoryFootprintMB().map { String(format: "%.0fMB", $0) } ?? "?"
                        let main = MainThreadWatchdog.shared.flushSummary() ?? "main: idle"
                        DiagnosticsLog.shared.append("PERF TICK footprint=\(mb) \(main)")
                        flushCounters("tick")
                    }
                    return t
                }
            }
        } else {
            MainThreadWatchdog.shared.stop()
            flushQueue.async { state.cancelTimer() }
        }
    }

    // MARK: - 時刻ヘルパ（手動計測用）

    /// 現在時刻（ns）。`msSince(_:)` と組み合わせて手動計測する。取得は安価なので無効時でも呼んでよい。
    public static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// `nowNs()` からの経過ミリ秒。
    public static func msSince(_ startNs: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000
    }

    // MARK: - スパン計測

    /// async ブロックの所要を計測してログする。無効時は body をそのまま実行する（オーバーヘッドなし）。
    public static func measureAsync<T>(_ label: @autoclosure () -> String,
                                       _ body: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let name = label()
        let sid = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "span", signpostID: sid, "%{public}@", name)
        let t0 = nowNs()
        defer {
            let ms = msSince(t0)
            os_signpost(.end, log: log, name: "span", signpostID: sid, "%{public}@ %.1fms", name, ms)
            DiagnosticsLog.shared.append(String(format: "PERF %@ %.1fms", name, ms))
        }
        return try await body()
    }

    /// 自分で計測した ms を 1 行ログする。バイト数やステータスなど付随情報を `detail` に書ける。
    public static func logSpan(_ label: String, ms: Double, detail: String = "") {
        guard isEnabled else { return }
        os_signpost(.event, log: log, name: "span", "%{public}@ %.1fms %{public}@", label, ms, detail)
        DiagnosticsLog.shared.append(String(format: "PERF %@ %.1fms %@", label, ms, detail))
    }

    /// ポイントイベント（時刻の目印）。
    public static func mark(_ label: @autoclosure () -> String) {
        guard isEnabled else { return }
        let name = label()
        os_signpost(.event, log: log, name: "mark", "%{public}@", name)
        DiagnosticsLog.shared.append("PERF MARK \(name)")
    }

    // MARK: - 画面遷移の計測（開始＝タップ/トリガ時、終了＝遷移先の onAppear 等）

    /// 画面遷移の**開始**（タップ/トリガ時）に呼ぶ。同じ `name` を `endScreen` に渡すと所要を出す。
    /// 無効時は何もしない（オーバーヘッドなし）。
    public static func beginScreen(_ name: @autoclosure () -> String) {
        guard isEnabled else { return }
        let n = name()
        state.beginScreen(n, at: nowNs())
    }

    /// 画面遷移の**完了**（遷移先の onAppear / 初回コンテンツ確定）で呼ぶ。
    /// 対応する `beginScreen` があれば所要 ms を、無ければ appear のマークだけ残す。
    public static func endScreen(_ name: @autoclosure () -> String) {
        guard isEnabled else { return }
        let n = name()
        let start = state.takeScreenStart(n)
        guard let start else { mark("screen.\(n) appear"); return }
        let ms = msSince(start)
        os_signpost(.event, log: log, name: "screen", "%{public}@ %.1fms", n, ms)
        DiagnosticsLog.shared.append(String(format: "PERF screen.%@ %.1fms", n, ms))
    }

    // MARK: - カウンタ集計（高頻度イベント向け）

    /// 高頻度イベントを集計するカウンタを 1 つ加算する。`value` は ms やバイトなどの付随量（任意）。
    /// 1 件ずつログすると氾濫する経路（サムネのキャッシュヒット等）はこちらで集計する。
    public static func count(_ key: @autoclosure () -> String, value: Double = 0) {
        guard isEnabled else { return }
        state.addCount(key(), value: value)
    }

    /// 集計済みカウンタを 1 行にまとめてログし、クリアする。区切りの良い箇所（バッチ完了など）で呼ぶ。
    public static func flushCounters(_ context: String = "") {
        guard isEnabled else { return }
        let snapshot = state.drainCounters()
        guard !snapshot.isEmpty else { return }
        let body = snapshot.sorted { $0.key < $1.key }.map { key, v in
            v.total > 0 ? String(format: "%@=%d(Σ%.1fms)", key, v.count, v.total) : "\(key)=\(v.count)"
        }.joined(separator: " ")
        DiagnosticsLog.shared.append("PERF COUNTERS \(context.isEmpty ? "" : context + " ")\(body)")
    }
}
