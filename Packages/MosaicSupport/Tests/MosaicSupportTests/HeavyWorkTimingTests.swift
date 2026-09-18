import Foundation
import Testing
@testable import MosaicSupport

/// AI 処理タイミングの判定（3 軸・ADR-80 → ADR-195）。
/// 軸は「自動処理の有無 / 電源 / 回線」で互いに独立。前面では「20 秒触っていない」だけを要求する
///（旧「控えめ＝前面では動かさない」の軸は ADR-195 で廃止＝操作中に譲るのは常時の挙動）。
@Suite("HeavyWorkTiming (3-axis gate)")
struct HeavyWorkTimingTests {

    /// 既定シナリオ: 自動処理オン・非使用・電源 OK・回線 OK。
    private func allows(_ t: HeavyWorkTiming = .enabled,
                        active: Bool = false, idle: Bool = false,
                        power: Bool = true, network: Bool = true,
                        requiresNetwork: Bool = true) -> Bool {
        t.allows(isAppActive: active, foregroundIdle: idle,
                 powerAllowed: power, networkAllowed: network,
                 requiresNetwork: requiresNetwork)
    }

    @Test("paused は常に不可（他の条件がすべて揃っていても）")
    func pausedNeverRuns() {
        #expect(!allows(.paused))
        #expect(!allows(.paused, active: true, idle: true))
    }

    @Test("前面: 20 秒触っていなければ動く・タッチ直後は動かない（ADR-195・設定不要）")
    func foregroundRunsWhenIdle() {
        #expect(allows(active: true, idle: true))
        #expect(!allows(active: true, idle: false))   // 操作直後
        #expect(allows(active: false))                 // 非使用は当然可
    }

    @Test("電源条件は独立して効く（前面・アイドルと無関係）")
    func powerAxisIsIndependent() {
        #expect(!allows(power: false))
        #expect(!allows(active: true, idle: true, power: false))
        #expect(allows(active: true, idle: true, power: true))
    }

    @Test("回線条件は『通信を要する作業』にだけ効く")
    func networkAxisAppliesOnlyToNetworkWork() {
        // 端末内写真の顔スキャン・CLIP 埋め込みは通信不要 → 回線 NG でも走る。
        #expect(allows(network: false, requiresNetwork: false))
        // 通信を要する作業（クラウド索引等）は回線条件が効く。
        #expect(!allows(network: false, requiresNetwork: true))
        // 回線 NG でも電源の安全弁は別途効く。
        #expect(!allows(power: false, network: false, requiresNetwork: false))
    }

    @Test("3 軸＋前面アイドルは互いに独立（どれか 1 つが NG なら不可・全部 OK なら可）")
    func axesAreIndependent() {
        let bools = [false, true]
        for active in bools { for idle in bools {
            for power in bools { for network in bools {
                let expected = !(active && !idle)     // 前面でタッチ直後 → 不可
                    && power                          // 電源 NG → 不可
                    && network                        // 回線 NG → 不可（requiresNetwork:true）
                #expect(allows(active: active, idle: idle, power: power, network: network) == expected,
                        "active=\(active) idle=\(idle) power=\(power) network=\(network)")
            }}
        }}
    }

    @Test("旧 paused(0) は自動処理オフへ（他は既定のまま）")
    func migratesPaused() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 0)
        #expect(plan.timing == .paused)
        #expect(plan.power == nil && plan.data == nil)
    }

    @Test("旧 nightly(1) は既定のまま（控えめ ON・電源/回線は触らない）")
    func migratesNightly() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 1)
        #expect(plan.timing == .enabled)
        #expect(plan.power == nil && plan.data == nil)
    }

    @Test("旧 chargeActive(2) は『前面でも動かしたい』＝控えめ OFF")
    func migratesChargeActive() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 2)
        #expect(plan.timing == .enabled)
        #expect(plan.power == nil && plan.data == nil)   // 電源は充電中のまま
    }

    @Test("旧 battery(3) は控えめ OFF ＋ 電源『常に』")
    func migratesBattery() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 3)
        #expect(plan.power == .always)
        #expect(plan.data == nil)                        // 回線は Wi-Fi のまま
    }

    @Test("旧 unlimited(4) は控えめ OFF ＋ 電源『常に』＋ 回線『セルラーも』")
    func migratesUnlimited() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 4)
        #expect(plan.power == .always)
        #expect(plan.data == .unrestricted)
    }

    @Test("未知の値は既定（自動処理オン・控えめ ON）へ倒す")
    func migratesUnknown() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 99)
        #expect(plan.timing == .enabled)
    }

    @Test("移行は 1 度だけ実行し、2 回目は既存の設定を上書きしない")
    func migrationRunsOnce() {
        let suite = "HeavyWorkTimingMigrationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用 UserDefaults を作れない"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(4, forKey: HeavyWorkTiming.defaultsKey)   // 旧 unlimited
        HeavyWorkTiming.migrateLegacySettingsIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: HeavyWorkTiming.defaultsKey) == HeavyWorkTiming.enabled.rawValue)
        #expect(defaults.integer(forKey: PowerStateMonitor.policyKey) == BackgroundPowerPolicy.always.rawValue)

        // 移行後にユーザーが「自動処理オフ」へ変えたら、再実行しても戻されない。
        defaults.set(HeavyWorkTiming.paused.rawValue, forKey: HeavyWorkTiming.defaultsKey)
        HeavyWorkTiming.migrateLegacySettingsIfNeeded(defaults: defaults)
        #expect(defaults.integer(forKey: HeavyWorkTiming.defaultsKey) == HeavyWorkTiming.paused.rawValue)
    }

    @Test("新規インストール（旧値なし）は何も書き換えない")
    func freshInstallKeepsDefaults() {
        let suite = "HeavyWorkTimingMigrationTests.fresh.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("テスト用 UserDefaults を作れない"); return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        HeavyWorkTiming.migrateLegacySettingsIfNeeded(defaults: defaults)
        #expect(defaults.object(forKey: HeavyWorkTiming.defaultsKey) == nil)
    }
}
