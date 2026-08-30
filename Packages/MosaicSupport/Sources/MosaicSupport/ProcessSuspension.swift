import Foundation

/// **プロセス中断（suspend）を検出**し、その間を跨いだ計測値を無効と判定するための番人。
///
/// ## なぜ必要か（実機ログ diagnostics-20 で判明）
/// バックグラウンド実行中、OS はアプリを任意のタイミングで suspend する。ところが計測に使っている
/// 時計は **suspend 中も進み続ける**（`CFAbsoluteTimeGetCurrent` は壁時計、
/// `DispatchTime.now().uptimeNanoseconds` も端末が起きていれば進む）。そのため:
///
/// - `MainThreadWatchdog` が「メインスレッドが **29 分**ブロックされた」と報告する
///   （実際は 10:22 に suspend、10:51 に resume しただけ）。
/// - `faces.detect` の `load=` 合計 1,868,367ms のうち **1,769,333ms が単一の外れ値**
///   （中央値は 81ms）。1 枚の画像ロードが suspend を跨いだだけ。
/// - `face.photoMs=1(Σ492753.8ms)`、`embed: batch ... in 1866.7s` も同じ汚染。
///
/// **背景実行を診断するために作った仕組みが、背景実行でこそ壊れていた。**
/// 汚染された値は「実機で重い処理が UI を止めていないか」の判断を不能にするので、
/// 計測側で中断を跨いだサンプルを捨てられるようにする。
///
/// ## 仕組み
/// 一定間隔（既定 1 秒）の `DispatchSourceTimer` を背景キューで回し、**自分の発火間隔**を見張る。
/// プロセスが suspend されるとこのタイマーも止まるため、resume 時に「予定より大幅に遅れて発火した」
/// ことで中断を検知できる（メインスレッドの状態とは独立に判定できるのが要点）。
/// 検知したら `epoch` を進める。計測側は開始時の `epoch` を覚えておき、終了時に
/// `didSuspend(since:)` が true なら**そのサンプルを捨てる**。
public enum ProcessSuspension {

    /// 可変状態のロック箱（保護なしのグローバル可変状態を作らない）。
    /// 不変条件: 状態はすべて private・アクセスは必ず lock 経由・同期メソッドのみ。
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var epoch = 0
        private var timer: DispatchSourceTimer?
        private var lastFire: Date?
        /// 直近の中断から復帰した時刻（uptime ns）。中断が無ければ nil。
        private var lastResumeNs: UInt64?

        var currentEpoch: Int {
            lock.lock(); defer { lock.unlock() }
            return epoch
        }

        /// 「いま終わった `ms` ミリ秒の計測」が中断を跨いでいるか。
        /// 計測の開始時刻（now - ms）より**後**に復帰していれば跨いでいる。
        func spanned(lastMs ms: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let lastResumeNs, ms > 0 else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = UInt64(max(0, min(ms, 1e15)) * 1_000_000)
            let start = now > elapsed ? now - elapsed : 0
            return lastResumeNs >= start
        }

        /// タイマー発火。予定より大幅に遅れていたら中断とみなす。
        /// 戻り値は「中断を検知したときの遅延秒」（検知しなければ nil）。
        func recordFire(interval: TimeInterval, tolerance: TimeInterval) -> TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            let now = Date()
            defer { lastFire = now }
            guard let lastFire else { return nil }          // 初回は基準が無い
            let delta = now.timeIntervalSince(lastFire)
            guard delta > interval + tolerance else { return nil }
            epoch &+= 1
            lastResumeNs = DispatchTime.now().uptimeNanoseconds
            return delta
        }

        /// テスト用: いま中断から復帰したことにする。
        func markResumeForTesting() {
            lock.lock(); defer { lock.unlock() }
            epoch &+= 1
            lastResumeNs = DispatchTime.now().uptimeNanoseconds
        }

        /// タイマー未設置なら設置する（二重 install を防ぐ）。
        func installTimerIfNeeded(_ make: () -> DispatchSourceTimer) {
            lock.lock(); defer { lock.unlock() }
            guard timer == nil else { return }
            lastFire = Date()
            let t = make()
            timer = t
            t.resume()
        }
    }

    private static let state = State()
    private static let queue = DispatchQueue(label: "com.mosaicphotos.suspension", qos: .utility)
    private static let interval: TimeInterval = 1
    /// この秒数を超える遅延を「中断」とみなす。GC・優先度低下による数百 ms の遅れでは誤検知しない。
    private static let tolerance: TimeInterval = 3

    /// 監視を開始する（`Diagnostics.install()` から 1 回だけ呼ぶ）。二重呼び出しは無害。
    public static func install() {
        state.installTimerIfNeeded {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
            t.setEventHandler {
                guard let delay = state.recordFire(interval: interval, tolerance: tolerance) else { return }
                DiagnosticsLog.shared.append(
                    String(format: "PROCESS SUSPENDED ~%.0fs — measurements spanning this gap are discarded",
                           delay))
            }
            return t
        }
    }

    /// 現在の中断世代。計測の開始時に控えておく。
    public static var epoch: Int { state.currentEpoch }

    /// `epoch` を控えた時点から今までの間に中断があったか。true ならその計測値は壁時計汚染されている。
    public static func didSuspend(since epoch: Int) -> Bool { state.currentEpoch != epoch }

    /// **開始時の epoch を控えていない計測**（`PerfTrace.logSpan(_:ms:)` のような後追い報告）向け。
    /// 所要 `ms` から開始時刻を逆算し、その後に復帰していれば「中断を跨いだ」と判定する。
    ///
    /// ⚠️ これが無いと、`PROCESS SUSPENDED` の行を出しておきながら**スパンは素通し**になる。
    /// 実機ログ（diagnostics-69）には `people.load.tuning 1612569.4ms`（27 分）が残り、
    /// 解析のたびに「27 分のハング」と読み違えかけた。番人を置いた意味が無くなる。
    public static func spanned(lastMs ms: Double) -> Bool { state.spanned(lastMs: ms) }

    /// テスト用: 中断→復帰を再現する（実際の suspend はテストから起こせない）。
    static func simulateSuspensionForTesting() { state.markResumeForTesting() }
}
