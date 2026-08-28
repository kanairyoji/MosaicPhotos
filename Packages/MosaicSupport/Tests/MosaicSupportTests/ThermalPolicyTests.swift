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
}
