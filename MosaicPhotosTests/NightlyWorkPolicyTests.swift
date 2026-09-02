import XCTest
@testable import MosaicPhotos

/// 夜間ウィンドウの使い方（ADR-163）。
///
/// ⚠️ 実機で 2 度失敗している判定なので、条件をここで固定する:
/// (1) 生成と解析を同じ窓で走らせると**両方とも終わらない**（diagnostics-72: 5 分の窓で
///     顔は 280 枚、生成は毎回 aborted）。
/// (2) かといって「残作業があるうちは永久に見送る」にすると、**生成が飢える**
///     （バックアップで同じ失敗をした＝ADR-72。残 44,017 枚に対し毎窓 192 枚しか進まず、
///     残 0 になるまでバックアップが一度も走らなかった）。
final class NightlyWorkPolicyTests: XCTestCase {

    private let maxDeferrals = 4

    func testDefersGenerationWhileAnalysisRemains() {
        let d = NightlyWorkPolicy.generateDecision(embedBacklog: 1200, faceBacklog: 0,
                                                   deferrals: 0, maxDeferrals: maxDeferrals)
        XCTAssertEqual(d, .defer_(streak: 1), "残作業があるのに生成を走らせている")

        let faces = NightlyWorkPolicy.generateDecision(embedBacklog: 0, faceBacklog: 20_078,
                                                       deferrals: 2, maxDeferrals: maxDeferrals)
        XCTAssertEqual(faces, .defer_(streak: 3), "顔の残作業でも見送るべき")
    }

    func testRunsGenerationWhenNothingRemains() {
        let d = NightlyWorkPolicy.generateDecision(embedBacklog: 0, faceBacklog: 0,
                                                   deferrals: 0, maxDeferrals: maxDeferrals)
        XCTAssertEqual(d, .run(afterDeferrals: 0))
    }

    /// ⚠️ ここが「生成を飢えさせない」保険。上限に達したら**残作業があっても**回す。
    func testGenerationGetsItsTurnAfterMaxDeferrals() {
        let atLimit = NightlyWorkPolicy.generateDecision(embedBacklog: 5_000, faceBacklog: 5_000,
                                                         deferrals: maxDeferrals,
                                                         maxDeferrals: maxDeferrals)
        XCTAssertEqual(atLimit, .run(afterDeferrals: maxDeferrals),
                       "上限に達しても見送り続けている＝生成が飢える")

        let justBelow = NightlyWorkPolicy.generateDecision(embedBacklog: 5_000, faceBacklog: 5_000,
                                                           deferrals: maxDeferrals - 1,
                                                           maxDeferrals: maxDeferrals)
        XCTAssertEqual(justBelow, .defer_(streak: maxDeferrals), "上限の 1 つ手前はまだ見送る")
    }

    /// 見送りの連鎖が上限に達したら 1 回だけ回り、次からまた数え直すこと（順番が回る）。
    func testDeferralStreakCyclesInsteadOfStalling() {
        var streak = 0
        var runs = 0
        for _ in 0..<12 {
            switch NightlyWorkPolicy.generateDecision(embedBacklog: 9_999, faceBacklog: 9_999,
                                                      deferrals: streak, maxDeferrals: maxDeferrals) {
            case .defer_(let next): streak = next
            case .run: runs += 1; streak = 0
            }
        }
        XCTAssertEqual(runs, 2, "12 窓で 2 回（5 窓に 1 回）生成が回るはず — 実際は \(runs) 回")
    }

    func testReconcileDueMirrorsBackupPolicy() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let week: TimeInterval = 7 * 24 * 60 * 60
        XCTAssertTrue(NightlyWorkPolicy.isReconcileDue(lastRun: nil, now: now, interval: week))
        XCTAssertFalse(NightlyWorkPolicy.isReconcileDue(lastRun: now.addingTimeInterval(-60),
                                                        now: now, interval: week))
        XCTAssertTrue(NightlyWorkPolicy.isReconcileDue(lastRun: now.addingTimeInterval(-week),
                                                       now: now, interval: week))
    }
}
