import Foundation
import Testing
@testable import MosaicSupport

/// diagnostics-81 の反省: **「動いていない時間」について、動き出した瞬間に書けることを書く**。
/// ここで固めるのは、その 2 つの純ロジック（前回の終わり方の要約・OS の終了理由の要約）。
@Suite("実行タイムライン")
struct RunTimelineTests {

    // MARK: - 前回どう終わったか

    @Test("正常終了なら何も書かない（ノイズを増やさない）")
    func idleProducesNothing() {
        #expect(RunTimeline.summary(state: "idle", at: Date(), now: Date()) == nil)
    }

    @Test("処理枠の途中で消えていたら、iOS による終了の疑いとして残す")
    func diedInsideWindow() {
        let now = Date()
        let line = RunTimeline.summary(state: "window", at: now.addingTimeInterval(-600), now: now)
        #expect(line?.contains("処理枠の途中") == true)
        #expect(line?.contains("10 分前") == true)
    }

    @Test("セッションの途中・未知の状態でも記録する")
    func otherStates() {
        let now = Date()
        #expect(RunTimeline.summary(state: "session", at: now, now: now)?.contains("セッションの途中") == true)
        #expect(RunTimeline.summary(state: "weird", at: nil, now: now)?.contains("時刻不明") == true)
    }

    // MARK: - OS が持っている終了理由

    @Test("0 の項目は書かず、起きた終了だけを日本語で並べる")
    func exitSummaryListsOnlyWhatHappened() {
        let line = RunTimeline.exitSummary(
            background: ["normal": 3, "memoryResourceLimit": 1, "watchdog": 0],
            foreground: ["normal": 0])
        #expect(line.contains("メモリ上限(jetsam)=1"))
        #expect(line.contains("正常終了=3"))
        #expect(!line.contains("ウォッチドッグ"), "0 件の理由まで並べるとノイズになる")
        #expect(line.contains("前面終了[なし]"))
    }

    @Test("窓が来ない原因になり得る終了理由に、ちゃんと名前が付いている")
    func labelsCoverTheImportantReasons() {
        #expect(RunTimeline.label(for: "memoryResourceLimit") == "メモリ上限(jetsam)")
        #expect(RunTimeline.label(for: "backgroundTaskTimeout") == "BGTask 期限超過")
        #expect(RunTimeline.label(for: "watchdog") == "ウォッチドッグ")
        #expect(RunTimeline.label(for: "unknownKey") == "unknownKey", "未知のキーはそのまま出す")
    }
}
