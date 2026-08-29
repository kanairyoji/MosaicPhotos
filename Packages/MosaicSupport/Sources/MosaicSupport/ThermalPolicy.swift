import Foundation

/// 発熱したら重い処理を止めるかの判定（純ロジック・テスト対象）。
///
/// ⚠️ なぜ要るか（実フィードバック）: 夜間の解析で端末が温まり、朝には
/// **iOS が「冷めてから充電します」の状態**になっていて充電が終わっていない。
/// 充電されないと翌晩も処理が進まず、発熱だけして前に進まない悪循環になる。
///
/// 既存の対応は `BackgroundTrickle.thermalPauseMultiplier()` で**休止を延ばす**だけだった。
/// 熱が上がり続ける状況では「遅くしながら発熱し続ける」ので、充電の阻害は解消しない。
/// **止める**判断が要る。
///
/// ヒステリシス（止める境界と再開の境界をずらす）を必ず入れる。同じ境界で止めて再開すると、
/// 境界付近で「止まる→少し冷える→再開→また上がる」を繰り返し、細かく動き続けて冷えない。
public enum ThermalPolicy {

    /// 止める温度域。`.serious` は OS が「性能に影響が出ている」と言う段階で、
    /// 充電の抑制もこのあたりから始まる。`.critical` まで待つと手遅れ。
    public static let stopState: ProcessInfo.ThermalState = .serious
    /// 再開してよい温度域。`.fair` までは戻さない（戻すとすぐ `.serious` へ跳ね返る）。
    public static let resumeState: ProcessInfo.ThermalState = .nominal

    /// **これ以上充電できていれば、熱でも止めない**（実フィードバック）。
    ///
    /// ⚠️ この停止は「熱いから危ない」ではなく「熱いと iOS が充電を止めるから」だった
    /// （ADR-118）。つまり守っているのは**充電**であって温度ではない。充電がほぼ終わっていれば
    /// 守るものが無いので、止める理由も無い——朝までに充電が終わらない、という当初の問題も起きない。
    /// 98%: 満充電付近では iOS 自身が充電速度を落とすうえ、表示も 100% と 99% を行き来する。
    /// 「100% ちょうど」を条件にすると、ほとんどの晩で条件を満たさない。
    public static let chargedEnoughLevel: Float = 0.98

    /// 熱による停止中か（純ロジック）。
    ///
    /// - Parameters:
    ///   - state: 現在の熱状態。
    ///   - wasPaused: 直前まで熱で止めていたか（ヒステリシスの状態）。
    ///   - isEnabled: 設定「充電をバックグラウンド処理より優先する」。OFF なら常に false。
    ///   - batteryLevel: 充電残量（0...1）。**不明なら nil**——不明を「満充電」と読むと
    ///     守るべき充電があるのに止めなくなるので、その場合は従来どおり熱で止める。
    /// - Returns: 止めるべきなら true。
    public static func shouldPause(state: ProcessInfo.ThermalState,
                                   wasPaused: Bool,
                                   isEnabled: Bool,
                                   batteryLevel: Float? = nil) -> Bool {
        guard isEnabled else { return false }
        // 充電がほぼ終わっているなら、熱を理由に止めない（守る対象が無い）。
        if let batteryLevel, batteryLevel >= chargedEnoughLevel { return false }
        if wasPaused {
            // 止めている間は、**十分に冷えるまで**再開しない（境界での往復を防ぐ）。
            return severity(state) > severity(resumeState)
        }
        return severity(state) >= severity(stopState)
    }

    /// 熱状態の順序（`ThermalState` は Comparable ではない）。
    public static func severity(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal:  return 0
        case .fair:     return 1
        case .serious:  return 2
        case .critical: return 3
        @unknown default: return 1   // 未知は中庸に倒す（止めも走らせもしない側へ寄せない）
        }
    }

    /// 表示用の短い説明（設定画面・診断ログ）。
    public static func label(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "normal"
        case .fair:     return "warm"
        case .serious:  return "hot"
        case .critical: return "very hot"
        @unknown default: return "unknown"
        }
    }
}

/// 熱による停止の現在状態（ヒステリシスを保持する）。
///
/// `ProcessInfo.thermalState` の読み出し自体は安いが、**状態を跨いだ判断**（止めていたか）が
/// 要るのでここで持つ。通知（`thermalStateDidChangeNotification`）は使わない——
/// 判定は 1 単位ごとに問い合わせる形（`BackgroundYield`）なので、その場で読めば足りる。
@MainActor
public final class ThermalGate {
    public static let shared = ThermalGate()

    /// 設定キー（`@AppStorage` と共用する唯一の出典）。
    public static let policyKey = "background.pauseWhenHot"

    /// 設定「充電をバックグラウンド処理より優先する」。**既定 ON**。
    ///
    /// ⚠️ 既定を ON にする理由: 発熱で充電が止まると翌晩も処理が進まない。
    /// OFF にすると「速いが充電されない」になり、結局トータルでは進まない。
    /// ⚠️ 充電がほぼ終わっていれば（`chargedEnoughLevel`）、ON のままでも処理は進む。
    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.policyKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.policyKey) }
    }

    /// 設定の読み書き先（テストは専用スイートを渡す）。
    private let defaults: UserDefaults

    private var paused = false
    /// 状態が変わったときだけ診断ログに残す（毎回書くとログが埋まる）。
    private var lastLoggedPaused: Bool?
    /// 状態が変わったときの通知（テストから記録を観測するための seam）。
    public var onTransition: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// いま熱で止めるべきか。1 単位ごとに呼ばれる前提（安い）。
    /// 充電残量は `PowerStateMonitor` から読む（満充電なら熱でも止めない・ADR-118 追補）。
    public func shouldPause(state: ProcessInfo.ThermalState
                            = ProcessInfo.processInfo.thermalState) -> Bool {
        shouldPause(state: state, batteryLevel: PowerStateMonitor.shared.batteryLevelIfKnown)
    }

    /// 残量を明示する形（テスト・診断から使う）。
    public func shouldPause(state: ProcessInfo.ThermalState, batteryLevel: Float?) -> Bool {
        let next = ThermalPolicy.shouldPause(state: state, wasPaused: paused,
                                             isEnabled: isEnabled, batteryLevel: batteryLevel)
        paused = next
        // ⚠️ **初回は記録しない**（実機 diagnostics-62）。起動のたびに
        // 「resuming（state=normal）」が出て、止まってもいないのに熱ゲートが働いたように読める。
        // 記録したいのは**状態が変わったとき**だけ。
        if lastLoggedPaused == nil { lastLoggedPaused = next }
        if lastLoggedPaused != next {
            lastLoggedPaused = next
            // 充電残量も残す（「熱いのに止まらない/止まる」の判断材料は温度だけでは足りない）。
            let battery = batteryLevel.map { "\(Int(($0 * 100).rounded()))%" } ?? "unknown"
            let line = "thermal: \(next ? "pausing" : "resuming") heavy work "
                + "(state=\(ThermalPolicy.label(state)), battery=\(battery))"
            Diagnostics.mark(line)
            onTransition?(line)
        }
        return next
    }

    /// テスト・デバッグ表示用。
    public var isPausedByHeat: Bool { paused }
}
