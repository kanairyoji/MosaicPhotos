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

    @Test("処理枠とセッションは互いの「実行中」を潰さない（レビュー指摘）")
    func twoStatesDoNotClobberEachOther() {
        let now = Date()
        // 窓とセッションが同時に走り、窓だけが終わった状態＝セッションはまだ実行中。
        #expect(RunTimeline.summary(state: "session", at: now, now: now) != nil)
        // 片方が終わっただけで「正常終了」と読まないこと（空の集合のときだけ nil）。
        #expect(RunTimeline.summary(state: "", at: now, now: now) == nil)
        #expect(RunTimeline.summary(state: "session+window", at: now, now: now) != nil,
                "両方が実行中のまま終了したら、当然それを残す")
    }

    @Test("旧ビルドの文字列パンくずも読める（版を上げた最初の起動で落とさない）")
    func legacyStringBreadcrumbStillReads() {
        // 旧形式は String 1 つ。配列として読むと nil になり、jetsam の痕跡が一番欲しい
        // 「版を上げた最初の起動」で証拠を落としていた（レビュー指摘）。
        let d = UserDefaults.standard
        let key = "runTimeline.state"
        let saved = d.object(forKey: key)
        defer { d.set(saved, forKey: key) }

        d.set("window", forKey: key)                 // 旧形式
        #expect(RunTimeline.previousRunSummary()?.contains("処理枠の途中") == true)

        d.set("idle", forKey: key)                   // 旧形式の正常終了
        #expect(RunTimeline.previousRunSummary() == nil)
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
