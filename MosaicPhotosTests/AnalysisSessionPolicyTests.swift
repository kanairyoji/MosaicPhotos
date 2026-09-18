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

/// diagnostics-81 の回帰: **中断されたセッションを「終わった」ことにしない**。
///
/// セッションはメモリ上の存在なので、ロック（iOS の既知の問題）・OS の期限切れ・
/// プロセス終了で消える。永続化していないと誰も気づかず、朝まで何も進まない。
final class AnalysisSessionPendingFlagTests: XCTestCase {

    func testInterruptionsKeepThePendingFlag() {
        XCTAssertTrue(AnalysisSessionPolicy.keepsPendingFlag(.expired), "OS に止められた＝やり残し")
        XCTAssertTrue(AnalysisSessionPolicy.keepsPendingFlag(.lowBattery), "電池切れ＝やり残し")
        XCTAssertTrue(AnalysisSessionPolicy.keepsPendingFlag(.leftScreen), "画面離脱＝やり残し")
    }

    func testDeferredKeepsTheFlagButIsNotAFailure() {
        // 回線待ちでクラウド分を次回に回した終わり方。印は残す（続きがある）が、
        // OS に「失敗」と報告する類のものではない（レビュー指摘）。
        XCTAssertTrue(AnalysisSessionPolicy.keepsPendingFlag(.deferred))
    }

    func testCompletionAndUserStopClearIt() {
        XCTAssertFalse(AnalysisSessionPolicy.keepsPendingFlag(.finished), "全部終わったら再開しない")
        XCTAssertFalse(AnalysisSessionPolicy.keepsPendingFlag(.user), "利用者が止めたら再開しない")
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

/// ADR-193: **アプリを離れたときの解析**（継続タスクを使う場面）の設定。
///
/// 選んでいるのは表示ではなく「継続タスクを使うか」——進捗 UI は OS が出すもので、
/// アプリからは消せない。だから「うるさい」への答えは使う場面を減らすことだけ。
final class AnalysisContinuationPolicyTests: XCTestCase {

    // MARK: - どの段で継続タスクを要求するか

    func testAlwaysKeepsGoingForBothManualAndAutoResume() {
        XCTAssertTrue(AnalysisContinuationPolicy.requestsContinuedTask(.always, autoResume: false))
        XCTAssertTrue(AnalysisContinuationPolicy.requestsContinuedTask(.always, autoResume: true))
    }

    func testManualOnlyKeepsGoingOnlyWhenTheUserTapped() {
        XCTAssertTrue(AnalysisContinuationPolicy.requestsContinuedTask(.manualOnly, autoResume: false))
        XCTAssertFalse(AnalysisContinuationPolicy.requestsContinuedTask(.manualOnly, autoResume: true),
                       "自動再開でインジケータが出るのが「うるさい」の主因")
    }

    func testWhileOpenNeverRequestsAContinuedTask() {
        XCTAssertFalse(AnalysisContinuationPolicy.requestsContinuedTask(.whileOpen, autoResume: false))
        XCTAssertFalse(AnalysisContinuationPolicy.requestsContinuedTask(.whileOpen, autoResume: true))
    }

    // MARK: - 自動再開の条件（電源必須・見ていない前面では走らせない）

    func testAutoResumeAlwaysRequiresPower() {
        for level in AnalysisContinuation.allCases {
            XCTAssertFalse(AnalysisContinuationPolicy.allowsAutoResume(level, onPower: false,
                                                                       statusScreenOpen: true),
                           "電池だけのときは自動再開しない（\(level)）")
        }
    }

    func testKeepGoingResumesEvenAwayFromTheScreen() {
        XCTAssertTrue(AnalysisContinuationPolicy.allowsAutoResume(.always, onPower: true,
                                                                  statusScreenOpen: false))
    }

    func testWithoutAContinuedTaskResumeNeedsTheScreenOpen() {
        XCTAssertFalse(AnalysisContinuationPolicy.allowsAutoResume(.manualOnly, onPower: true,
                                                                   statusScreenOpen: false),
                       "見ていない前面で重い処理を走らせない（ADR-25）")
        XCTAssertTrue(AnalysisContinuationPolicy.allowsAutoResume(.manualOnly, onPower: true,
                                                                  statusScreenOpen: true))
        XCTAssertFalse(AnalysisContinuationPolicy.allowsAutoResume(.whileOpen, onPower: true,
                                                                   statusScreenOpen: false))
        XCTAssertTrue(AnalysisContinuationPolicy.allowsAutoResume(.whileOpen, onPower: true,
                                                                  statusScreenOpen: true))
    }

    // MARK: - 既定値（移行なしで現行動作のまま）

    func testDefaultIsKeepGoing() {
        XCTAssertEqual(AnalysisContinuation.default, .always)
        XCTAssertEqual(AnalysisContinuation(rawValue: 0), .always, "未設定(0)＝現行動作")
    }
}
