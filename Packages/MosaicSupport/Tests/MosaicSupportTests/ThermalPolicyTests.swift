import Foundation
import Testing
@testable import MosaicSupport

/// ⚠️ 夜間の解析で端末が温まり、朝には iOS が「冷めてから充電します」に入っていて
/// 充電が終わっていない（実フィードバック）。充電されないと翌晩も進まず、
/// 発熱だけして前に進まない悪循環になる。既存の対応（休止を延ばす）では止まらない。
@Suite("発熱時の停止判定")
struct ThermalPolicyTests {

    private func pause(_ state: ProcessInfo.ThermalState, wasPaused: Bool = false,
                       enabled: Bool = true) -> Bool {
        ThermalPolicy.shouldPause(state: state, wasPaused: wasPaused, isEnabled: enabled)
    }

    @Test("熱くなったら止める")
    func stopsWhenHot() {
        #expect(pause(.serious))
        #expect(pause(.critical))
    }

    @Test("温かい程度では止めない")
    func keepsRunningWhenWarm() {
        #expect(!pause(.nominal))
        #expect(!pause(.fair), "この段階で止めると夜間に何も進まない")
    }

    /// 止める境界と再開の境界を同じにすると、境界付近で止まる／動くを繰り返して冷えない。
    @Test("止めた後は十分に冷えるまで再開しない")
    func hysteresisPreventsFlapping() {
        #expect(pause(.fair, wasPaused: true), "止めた直後に fair へ下がっただけで再開しない")
        #expect(pause(.serious, wasPaused: true))
        #expect(!pause(.nominal, wasPaused: true), "十分に冷えたら再開する")
    }

    @Test("設定が OFF なら止めない")
    func disabledNeverPauses() {
        #expect(!pause(.critical, enabled: false))
        #expect(!pause(.serious, wasPaused: true, enabled: false))
    }

    @Test("熱状態の順序が正しい")
    func severityOrder() {
        #expect(ThermalPolicy.severity(.nominal) < ThermalPolicy.severity(.fair))
        #expect(ThermalPolicy.severity(.fair) < ThermalPolicy.severity(.serious))
        #expect(ThermalPolicy.severity(.serious) < ThermalPolicy.severity(.critical))
    }

    @Test("止める境界は再開の境界より高い")
    func stopIsAboveResume() {
        #expect(ThermalPolicy.severity(ThermalPolicy.stopState)
                > ThermalPolicy.severity(ThermalPolicy.resumeState),
                "同じだと境界で往復して冷えない")
    }
}

@Suite("発熱ゲートの状態保持")
@MainActor
struct ThermalGateTests {

    /// 共有インスタンス（`.standard`）を汚さないよう、専用スイートで作る。
    private func makeGate(enabled: Bool = true) -> ThermalGate {
        let defaults = UserDefaults(suiteName: "thermal-\(UUID().uuidString)") ?? .standard
        let gate = ThermalGate(defaults: defaults)
        gate.isEnabled = enabled
        return gate
    }

    @Test("止めた状態を跨いで覚えている")
    func remembersPausedState() {
        let gate = makeGate()
        #expect(gate.shouldPause(state: .serious))
        #expect(gate.shouldPause(state: .fair), "冷えかけでは再開しない")
        #expect(!gate.shouldPause(state: .nominal))
        #expect(!gate.isPausedByHeat)
    }

    @Test("OFF なら何があっても止めない")
    func disabledGate() {
        let gate = makeGate(enabled: false)
        #expect(!gate.shouldPause(state: .critical))
    }

    /// 既定は ON。発熱で充電が止まると翌晩も進まないので、明示的に切らない限り守る。
    @Test("既定は ON")
    func defaultIsEnabled() {
        let defaults = UserDefaults(suiteName: "thermal-default-\(UUID().uuidString)") ?? .standard
        #expect(ThermalGate(defaults: defaults).isEnabled)
    }

    @Test("設定は保存される")
    func settingPersists() {
        let defaults = UserDefaults(suiteName: "thermal-persist-\(UUID().uuidString)") ?? .standard
        ThermalGate(defaults: defaults).isEnabled = false
        #expect(!ThermalGate(defaults: defaults).isEnabled)
    }

    /// ⚠️ 実機 diagnostics-62 では、起動のたびに「resuming（state=normal）」が記録され、
    /// **止まってもいないのに熱ゲートが働いたように読めた**（6 件すべてが初回の記録）。
    /// 記録したいのは状態が変わったときだけ。
    @Test("初回は記録しない（止まっていないのに resuming と出さない）")
    func firstCallIsNotLogged() {
        let gate = makeGate()
        var lines: [String] = []
        gate.onTransition = { lines.append($0) }

        #expect(!gate.shouldPause(state: .nominal))
        #expect(lines.isEmpty, "起動しただけで熱ゲートが働いたように見える")

        #expect(gate.shouldPause(state: .serious))
        #expect(lines.count == 1, "本当に止まったときは記録する")
    }
}

/// 「充電がほぼ終わっていれば、熱でも止めない」（ADR-118 追補）。
///
/// ⚠️ この停止は**温度を守るためではなく充電を守るため**にある。満充電なら守る対象が無いので、
/// 止める理由も無い——ここを取り違えると「熱いから安全のため止めている」という別のルールに
/// なってしまう（そう読める実装は、あとから条件を足すときに必ず食い違う）。
@Suite("満充電なら熱でも止めない")
struct ThermalPolicyChargedTests {

    @Test("熱くても満充電付近なら止めない")
    func fullBatteryKeepsWorking() {
        #expect(!ThermalPolicy.shouldPause(state: .serious, wasPaused: false, isEnabled: true,
                                           batteryLevel: 1.0))
        #expect(!ThermalPolicy.shouldPause(state: .critical, wasPaused: true, isEnabled: true,
                                           batteryLevel: ThermalPolicy.chargedEnoughLevel))
    }

    @Test("充電が残っているなら従来どおり熱で止める")
    func chargingBatteryStillPauses() {
        #expect(ThermalPolicy.shouldPause(state: .serious, wasPaused: false, isEnabled: true,
                                          batteryLevel: 0.80))
        // ヒステリシス（止めている間は十分冷えるまで再開しない）も残量に関わらず効く。
        #expect(ThermalPolicy.shouldPause(state: .fair, wasPaused: true, isEnabled: true,
                                          batteryLevel: 0.97))
    }

    /// ⚠️ 残量**不明**を満充電と読むと、守るべき充電があるのに止めなくなる。不明は従来どおり止める。
    @Test("残量が分からないときは従来どおり止める")
    func unknownBatteryPauses() {
        #expect(ThermalPolicy.shouldPause(state: .serious, wasPaused: false, isEnabled: true,
                                          batteryLevel: nil))
    }

    @Test("設定 OFF なら残量に関わらず止めない")
    func disabledNeverPauses() {
        #expect(!ThermalPolicy.shouldPause(state: .critical, wasPaused: true, isEnabled: false,
                                           batteryLevel: 0.10))
    }
}
