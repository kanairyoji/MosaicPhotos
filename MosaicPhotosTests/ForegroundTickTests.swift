import XCTest
@testable import MosaicPhotos

/// ホームの前面の定期ループ（場所・撮影日時・自動アルバム）の判断。
/// 以前は 3 本のループが `HomeView` の中で同じ判断を書き写していて、テストが無かった。
@MainActor
final class ForegroundTickTests: XCTestCase {

    private typealias Env = ForegroundTick.Environment

    /// 環境 8 通り × 要求の組み合わせ 4 通りを総当たりする。
    func testShouldRunAcrossAllCombinations() {
        let requirementSets: [Set<ForegroundTick.Requirement>] =
            [[], [.cloudTrickle], [.dropboxConnected], [.cloudTrickle, .dropboxConnected]]
        var cases = 0, ran = 0
        for background in [false, true] {
            for trickle in [false, true] {
                for connected in [false, true] {
                    let env = Env(isInBackground: background, allowsCloudTrickle: trickle,
                                  isDropboxConnected: connected)
                    for requires in requirementSets {
                        cases += 1
                        let expected = !background
                            && (!requires.contains(.cloudTrickle) || trickle)
                            && (!requires.contains(.dropboxConnected) || connected)
                        let actual = ForegroundTick.shouldRun(requires: requires, env)
                        XCTAssertEqual(actual, expected, "env=\(env) requires=\(requires)")
                        if actual { ran += 1 }
                    }
                }
            }
        }
        // 網羅していること・両方の結果が出ていることを確かめる（空振りしない）。
        XCTAssertEqual(cases, 32)
        XCTAssertEqual(ran, 9)
    }

    /// ⚠️ 背面では、何も要求しないループ（自動アルバム）でも走らない（diagnostics-74）。
    func testBackgroundNeverRunsEvenWithoutRequirements() {
        let env = Env(isInBackground: true, allowsCloudTrickle: true, isDropboxConnected: true)
        XCTAssertFalse(ForegroundTick.shouldRun(requires: [], env))
        XCTAssertTrue(ForegroundTick.shouldRun(
            requires: [], Env(isInBackground: false, allowsCloudTrickle: false, isDropboxConnected: false)))
    }

    /// 続きが残っているときだけ短い間隔。走らなかった回・残っていない回は既定の間隔。
    func testNextDelay() {
        XCTAssertEqual(ForegroundTick.nextDelay(after: .ran(hasMore: true), interval: 60, busyInterval: 3), 3)
        XCTAssertEqual(ForegroundTick.nextDelay(after: .ran(hasMore: false), interval: 60, busyInterval: 3), 60)
        XCTAssertEqual(ForegroundTick.nextDelay(after: .skipped, interval: 60, busyInterval: 3), 60)
        XCTAssertEqual(ForegroundTick.nextDelay(after: .ran(hasMore: true), interval: 60, busyInterval: nil), 60)
    }

    /// 骨格: `start` は 1 回だけ、`tick` は条件が揃った回だけ、キャンセルで抜ける。
    func testRunCallsStartOnceAndTicksOnlyWhenAllowed() async {
        final class Counter { var start = 0, ticks = 0, envReads = 0 }
        let counter = Counter()
        // 背面 → 前面 → 背面 → 前面 … と交互に返し、5 回目の判断で止める。
        let task = Task { @MainActor in
            await ForegroundTick.run(.init(
                initialDelay: 0,
                start: { counter.start += 1 },
                sleepsBeforeFirstTick: false,
                requires: [],
                busyInterval: nil,
                tick: { counter.ticks += 1; return false }),
                interval: { 0 },
                environment: {
                    counter.envReads += 1
                    if counter.envReads >= 5 { withUnsafeCurrentTask { $0?.cancel() } }
                    return Env(isInBackground: counter.envReads % 2 == 1,
                               allowsCloudTrickle: true, isDropboxConnected: true)
                })
        }
        await task.value
        XCTAssertEqual(counter.start, 1)
        XCTAssertEqual(counter.envReads, 5)
        // 判断 5 回のうち前面は 2 回目と 4 回目だけ（5 回目は背面）。
        XCTAssertEqual(counter.ticks, 2)
    }
}
