import XCTest
@testable import MosaicPhotos

/// 解析セッション（ADR-182）の判断。
final class AnalysisSessionPolicyTests: XCTestCase {

    func testBatteryStopOnlyOffPowerBelowFloor() {
        XCTAssertTrue(AnalysisSessionPolicy.shouldStopForBattery(onPower: false, level: 0.19))
        XCTAssertFalse(AnalysisSessionPolicy.shouldStopForBattery(onPower: true, level: 0.05), "充電中は止めない")
        XCTAssertFalse(AnalysisSessionPolicy.shouldStopForBattery(onPower: false, level: 0.5))
        XCTAssertFalse(AnalysisSessionPolicy.shouldStopForBattery(onPower: false, level: -1), "残量不明なら止めない")
    }

    func testProgressNeverExceedsTotalAndWarmupCounts() {
        let p0 = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 100, warmupTicks: 0)
        XCTAssertEqual(p0.completed, 0)
        XCTAssertEqual(p0.total, 100 + AnalysisSessionPolicy.warmupUnits)
        let warm = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 100, warmupTicks: 5)
        XCTAssertEqual(warm.completed, 5, "準備中も進捗が進む（報告なしは OS に殺される）")
        let over = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 0, warmupTicks: 999)
        XCTAssertEqual(over.completed, over.total, "上限で頭打ち")
        let grew = AnalysisSessionPolicy.progressUnits(peakRemaining: 100, remaining: 150, warmupTicks: 0)
        XCTAssertEqual(grew.completed, 0, "残りが分母を超えても負にならない")
    }

    func testFinishedRequiresFaceScanSettled() {
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: false, scanning: false, faceScanSettled: false),
                       "顔スキャンが始まる前の残 0 は「未確定」")
        XCTAssertTrue(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: false, scanning: false, faceScanSettled: true))
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 0, tagging: true, scanning: false, faceScanSettled: true))
        XCTAssertFalse(AnalysisSessionPolicy.isFinished(remaining: 3, tagging: false, scanning: false, faceScanSettled: true))
    }

    func testRemainingClampsNegatives() {
        XCTAssertEqual(AnalysisSessionPolicy.remaining(faces: -1, tagsPending: 2, embedPending: -5), 2)
    }
}
/// diagnostics-81 の追補: **「なぜ進まないか」をアプリ自身が言える**こと。
final class AnalysisBlockerDiagnosisTests: XCTestCase {

    private func blockers(automatic: Bool = true, refresh: Bool = true, lowPower: Bool = false,
                          requiresPower: Bool = true, onPower: Bool = true,
                          hot: Bool = false, network: Bool = true) -> [AnalysisBlockerDiagnosis.Blocker] {
        AnalysisBlockerDiagnosis.blockers(automaticEnabled: automatic,
                                          backgroundRefreshAvailable: refresh,
                                          lowPowerMode: lowPower,
                                          requiresPower: requiresPower,
                                          onPower: onPower,
                                          thermalPaused: hot,
                                          networkAllowed: network)
    }

    func testNoBlockersWhenEverythingIsSatisfied() {
        XCTAssertTrue(blockers().isEmpty)
    }

    func testEachConditionIsReported() {
        XCTAssertEqual(blockers(automatic: false), [.automaticOff])
        XCTAssertEqual(blockers(refresh: false), [.backgroundRefreshOff])
        XCTAssertEqual(blockers(lowPower: true), [.lowPowerMode])
        XCTAssertEqual(blockers(onPower: false), [.notCharging])
        XCTAssertEqual(blockers(hot: true), [.tooHot])
        XCTAssertEqual(blockers(network: false), [.networkBlocked])
    }

    func testChargingIsNotRequiredWhenThePolicySaysAlways() {
        XCTAssertTrue(blockers(requiresPower: false, onPower: false).isEmpty,
                      "電源ポリシーが「常に」なら、充電していなくても理由にはならない")
    }

    func testStarvationOnlyCountsWhenNothingElseBlocks() {
        XCTAssertTrue(AnalysisBlockerDiagnosis.isWindowStarved(blockers: [], minutesSinceLastWindow: 13 * 60))
        XCTAssertFalse(AnalysisBlockerDiagnosis.isWindowStarved(blockers: [], minutesSinceLastWindow: 60),
                       "数時間の空白は正常（OS の裁量）")
        XCTAssertFalse(AnalysisBlockerDiagnosis.isWindowStarved(blockers: [.notCharging],
                                                               minutesSinceLastWindow: 24 * 60),
                       "理由が分かっているときは「枠が来ない」と言わない")
        XCTAssertFalse(AnalysisBlockerDiagnosis.isWindowStarved(blockers: [], minutesSinceLastWindow: nil),
                       "一度も開いていない端末では判断しない")
    }
}
/// ADR-195: 常設の方針を評価して残作業を進める駆動役の判断。
/// 「再開」は無い——条件が揃っていれば起こし、揃っていなければ何もしない、だけ。
final class AnalysisDriverPolicyTests: XCTestCase {

    private func decide(_ trigger: AnalysisDriver.Trigger, active: Bool = true, allowed: Bool = true,
                        boost: Bool = false, since: TimeInterval = 999) -> AnalysisDriverPolicy.Decision {
        AnalysisDriverPolicy.decide(trigger: trigger, appActive: active, allowed: allowed,
                                    boostActive: boost, sinceLastKick: since)
    }

    func testKicksWhenPolicyAllowsInForeground() {
        XCTAssertEqual(decide(.foreground), .kick)
        XCTAssertEqual(decide(.power), .kick)
        XCTAssertEqual(decide(.idle), .kick)
    }

    func testBackgroundIsLeftToTheProcessingWindow() {
        XCTAssertEqual(decide(.power, active: false), .background, "背面は処理枠の管轄＝駆動役は起こさない")
    }

    func testDoesNotStackOnTopOfABoost() {
        XCTAssertEqual(decide(.idle, boost: true), .boostActive)
    }

    func testRespectsThePolicy() {
        XCTAssertEqual(decide(.foreground, allowed: false), .notAllowed, "電源・回線・アイドル・自動処理オフは方針が決める")
    }

    func testIdleTriggerIsThrottledButOthersAreNot() {
        XCTAssertEqual(decide(.idle, since: 10), .throttled, "5 秒ごとの検知をそのまま毎回起こさない")
        XCTAssertEqual(decide(.idle, since: AnalysisDriverPolicy.idleKickInterval), .kick)
        XCTAssertEqual(decide(.power, since: 0), .kick, "条件の変化は即座に反映する")
        XCTAssertEqual(decide(.boostEnded, since: 0), .kick)
    }
}
