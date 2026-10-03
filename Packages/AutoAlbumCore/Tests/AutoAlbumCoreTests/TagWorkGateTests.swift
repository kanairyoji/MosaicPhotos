import Foundation
import Testing
@testable import AutoAlbumCore

/// **やることが無い回に、重い準備をしない**（ADR-247・実機ログ diagnostics-102）。
///
/// ⚠️⚠️ **なぜ既存テストで捕まらなかったか**（ここが本題）。
/// `TricklePlanTests` は「どの手を・どの順でやるか」を純ロジックとして丁寧に固定している。
/// `tagUnprocessed` にも「タグ付け済みは飛ばす」「上限で畳む」のテストがある。
/// それでも実機で **1 ステップ +341MB** を見逃した。見ていなかったのは
/// **「その手を始める前に、どれだけ読むか」**だった。
///
/// - `TricklePlan` は *何をやるか* を決めるが、*その準備にいくら払うか* は見ていない。
/// - `tagUnprocessed` のテストは *渡された候補* に対する振る舞いを見るので、
///   **候補を作る費用**（8.6 万行の列挙 ×2 ＋ 8.6 万件のソート）はテストの外にあった。
/// - ⚠️ しかも準備は**呼び出し側**（`AutoAlbumEngine+Recognition.perform`）にあり、
///   そこは `@MainActor` のファサードでテストが薄い。**費用は境界をまたいだ向こう側**に居た。
///
/// → だからここでは「**やることがあるか**」を安い数だけで答える規則を取り出して固定する。
/// 同型: `CaptureDateFillGate`（ADR-243）。同じ形が 3 つ目なので、**判断は必ず純 enum へ出す**。
@Suite("シーンタグ付けを走らせる条件（ADR-247）")
struct TagWorkGateTests {

    @Test("記録が無ければ必ず走る（初回から飛ばさない）")
    func firstRunAlwaysRuns() {
        #expect(!TagWorkGate.canSkip(enriched: 86_772, tagged: 86_772,
                                     lastEnriched: nil, lastTagged: nil))
        // 片方だけ覚えている（版の途中で足した）場合も走る＝安全側。
        #expect(!TagWorkGate.canSkip(enriched: 86_772, tagged: 86_772,
                                     lastEnriched: 86_772, lastTagged: nil))
        #expect(!TagWorkGate.canSkip(enriched: 86_772, tagged: 86_772,
                                     lastEnriched: nil, lastTagged: 86_772))
    }

    /// ⚠️ 実機で毎回払っていたぶん。どちらも動いていなければ、前回の結論は変わらない。
    @Test("どちらも動いていなければ飛ばす")
    func skipsWhenNothingMoved() {
        #expect(TagWorkGate.canSkip(enriched: 86_772, tagged: 86_772,
                                    lastEnriched: 86_772, lastTagged: 86_772))
    }

    @Test("写真が増えたら走る（タグ付けすべき写真が増えた）")
    func runsWhenPhotosWereAdded() {
        #expect(!TagWorkGate.canSkip(enriched: 86_800, tagged: 86_772,
                                     lastEnriched: 86_772, lastTagged: 86_772))
    }

    /// ⚠️ 版を上げるとタグ付け済みの数が**減る**（旧版の記録は数えない）。
    /// 「増えたときだけ走る」にすると、版を上げた晩に 1 枚もタグ付けしない。
    @Test("タグ付け済みの数が減っても走る（版を上げたとき）")
    func runsWhenTaggedCountDropped() {
        #expect(!TagWorkGate.canSkip(enriched: 86_772, tagged: 0,
                                     lastEnriched: 86_772, lastTagged: 86_772))
    }

    @Test("タグ付けが進んだら走る（残りがまだあるかもしれない）")
    func runsWhenProgressWasMade() {
        #expect(!TagWorkGate.canSkip(enriched: 86_772, tagged: 40,
                                     lastEnriched: 86_772, lastTagged: 0))
    }

    // MARK: - 札を立ててよいか（ADR-253・台帳の宿題）

    /// ⚠️⚠️ **ゲートで本当に危ないのはこちら**。`canSkip` の誤りは「無駄に +341MB 払う」だけだが、
    /// 札を立てる条件の誤りは「**残りが永久にタグ付けされない**」になる。
    /// それなのにこの判断は呼び出し側にインラインで書かれていて、テストが無かった。
    @Test("本当に終わった回だけ札を立てる（remaining == 0）")
    func recordsOnlyWhenTrulyDone() {
        #expect(TagWorkGate.shouldRecord(remaining: 0))
    }

    /// 上限（`maxBatches`）で打ち切った回に立てると、次からずっと飛ばす。
    @Test("上限で打ち切った回は札を立てない")
    func doesNotRecordWhenTruncated() {
        #expect(!TagWorkGate.shouldRecord(remaining: 1))
        #expect(!TagWorkGate.shouldRecord(remaining: 24_505))
    }

    /// ⚠️ **nil（走れなかった）を 0（終わった）と混ぜない**（ADR-207/242/253）。
    /// provider 無し・二重起動で 1 枚も処理していないのに札が立つと、
    /// その端末ではタグ付けが二度と始まらない。
    @Test("走れなかった回（nil）は札を立てない — 0 と混ぜない")
    func doesNotRecordWhenItCouldNotRun() {
        #expect(!TagWorkGate.shouldRecord(remaining: nil))
        // 0 と nil は別の意味であること（取り違えると向きが逆になる）。
        #expect(TagWorkGate.shouldRecord(remaining: 0))
    }
}
