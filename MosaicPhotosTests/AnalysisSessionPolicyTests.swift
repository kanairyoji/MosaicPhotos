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
