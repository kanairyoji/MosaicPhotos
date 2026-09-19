import Foundation
import Testing
@testable import MosaicSupport

/// `HeavyWorkTiming` が持つのは「自動処理する/しない」の軸と、旧 5 段階からの移行だけ。
/// **どの条件をどの仕事に課すか**はゲート表（`BackgroundGateTests`）が検証する（ADR-196）。
@Suite("HeavyWorkTiming（自動処理の軸と移行）")
struct HeavyWorkTimingTests {

    @Test("既定は enabled・0 だけが paused（旧 2/3/4 は移行で畳まれる）")
    func currentReadsRawValue() {
        #expect(HeavyWorkTiming.paused.rawValue == 0)
        #expect(HeavyWorkTiming.enabled.rawValue == 1)
    }

    @Test("前面のアイドル秒は 20 秒（ADR-195）")
    func foregroundIdleIsTwentySeconds() {
        #expect(HeavyWorkTiming.foregroundIdleSeconds == 20)
    }

    @Test("移行: 旧 0（停止）は自動処理オフ、電源・回線は触らない")
    func migratesPaused() {
        let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: 0)
        #expect(plan.timing == .paused)
        #expect(plan.power == nil)
        #expect(plan.data == nil)
    }

    @Test("移行: 旧 3（battery）は電源「常に」・旧 4（unlimited）は回線も緩める")
    func migratesLoosenedLevels() {
        let battery = HeavyWorkTiming.migrationPlan(legacyRawValue: 3)
        #expect(battery.timing == .enabled)
        #expect(battery.power == .always)
        #expect(battery.data == nil)

        let unlimited = HeavyWorkTiming.migrationPlan(legacyRawValue: 4)
        #expect(unlimited.power == .always)
        #expect(unlimited.data == .unrestricted)
    }

    @Test("移行: 旧 1/2 と未知の値は既定（enabled・電源と回線は触らない）")
    func migratesDefaults() {
        for raw in [1, 2, 99] {
            let plan = HeavyWorkTiming.migrationPlan(legacyRawValue: raw)
            #expect(plan.timing == .enabled, "raw=\(raw)")
            #expect(plan.power == nil)
            #expect(plan.data == nil)
        }
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
