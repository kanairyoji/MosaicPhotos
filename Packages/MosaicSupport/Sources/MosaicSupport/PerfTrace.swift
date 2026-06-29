import Foundation
import os

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
    public static var isEnabled = true
#else
    public static var isEnabled = false
#endif

    private static let log = OSLog(subsystem: "com.mosaicphotos.perf", category: "PointsOfInterest")
    private static let lock = NSLock()
    private static var counters: [String: (count: Int, total: Double)] = [:]

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

    private static var pendingScreens: [String: UInt64] = [:]

    /// 画面遷移の**開始**（タップ/トリガ時）に呼ぶ。同じ `name` を `endScreen` に渡すと所要を出す。
    /// 無効時は何もしない（オーバーヘッドなし）。
    public static func beginScreen(_ name: @autoclosure () -> String) {
        guard isEnabled else { return }
        let n = name()
        lock.lock(); pendingScreens[n] = nowNs(); lock.unlock()
    }

    /// 画面遷移の**完了**（遷移先の onAppear / 初回コンテンツ確定）で呼ぶ。
    /// 対応する `beginScreen` があれば所要 ms を、無ければ appear のマークだけ残す。
    public static func endScreen(_ name: @autoclosure () -> String) {
        guard isEnabled else { return }
        let n = name()
        lock.lock(); let start = pendingScreens.removeValue(forKey: n); lock.unlock()
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
        let k = key()
        lock.lock(); defer { lock.unlock() }
        var e = counters[k] ?? (0, 0)
        e.count += 1
        e.total += value
        counters[k] = e
    }

    /// 集計済みカウンタを 1 行にまとめてログし、クリアする。区切りの良い箇所（バッチ完了など）で呼ぶ。
    public static func flushCounters(_ context: String = "") {
        guard isEnabled else { return }
        lock.lock(); let snapshot = counters; counters.removeAll(); lock.unlock()
        guard !snapshot.isEmpty else { return }
        let body = snapshot.sorted { $0.key < $1.key }.map { key, v in
            v.total > 0 ? String(format: "%@=%d(Σ%.1fms)", key, v.count, v.total) : "\(key)=\(v.count)"
        }.joined(separator: " ")
        DiagnosticsLog.shared.append("PERF COUNTERS \(context.isEmpty ? "" : context + " ")\(body)")
    }
}
