import Foundation
import Testing
@testable import PerceptionCore

/// 「動くべき解析パスが動いていない」の検出（ADR-87）。
/// 過去 3 件の飢餓バグ（ADR-72/85/86）を**シナリオとして固定**し、同じ沈黙を次は見逃さない。
@Suite("AnalysisStallCheck")
struct AnalysisStallCheckTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    private func state(_ pass: AnalysisActivity.Pass, pending: Int, lastDaysAgo: Double?)
        -> AnalysisStallCheck.PassState {
        .init(pass: pass, pending: pending, lastActivity: lastDaysAgo.map(daysAgo))
    }

    @Test("残作業が無いパスは、長く動いていなくても停滞ではない")
    func noPendingIsNotStalled() {
        let states = [state(.embeddings, pending: 0, lastDaysAgo: 30)]
        #expect(AnalysisStallCheck.stalled(states, now: now).isEmpty)
    }

    @Test("最近動いていれば停滞ではない")
    func recentActivityIsNotStalled() {
        let states = [state(.sceneTags, pending: 24_505, lastDaysAgo: 0.5)]
        #expect(AnalysisStallCheck.stalled(states, now: now).isEmpty)
    }

    @Test("残作業があり猶予を超えて動いていなければ停滞")
    func pendingAndIdleIsStalled() {
        let states = [state(.embeddings, pending: 43_626, lastDaysAgo: 10)]
        #expect(AnalysisStallCheck.stalled(states, now: now) == [.embeddings])
    }

    /// ADR-85 の実バグ: タグは進むが埋め込みが数週間 0 枚だった状況。
    @Test("実バグ再現(ADR-85): タグは動いているのに埋め込みだけ停滞している")
    func historicalEmbeddingStarvation() {
        let states = [
            state(.sceneTags, pending: 24_505, lastDaysAgo: 0.1),    // 進んでいる
            state(.embeddings, pending: 43_626, lastDaysAgo: 21),    // 3 週間動いていない
            state(.faces, pending: 67_377, lastDaysAgo: 0.2),        // 進んでいる
        ]
        #expect(AnalysisStallCheck.stalled(states, now: now) == [.embeddings])
    }

    /// ADR-86 の実バグと同型（当時は VLM キャプション＝現在は廃止）: あるパスが一度も
    /// 生成されない状況。「一度も動いていない」は `installedAt` からの経過で判定する。
    @Test("実バグ再現(ADR-86): 一度も動いていないパスを導入時刻から検出する")
    func historicalStarvation() {
        let states = [
            state(.embeddings, pending: 1_383, lastDaysAgo: nil),    // 一度も動いていない
            state(.faces, pending: 67_377, lastDaysAgo: 0.2),
        ]
        #expect(AnalysisStallCheck.stalled(states, now: now, installedAt: daysAgo(14)) == [.embeddings])
    }

    @Test("新規インストール直後は、一度も動いていなくても停滞としない")
    func freshInstallIsNotStalled() {
        let states = [state(.embeddings, pending: 1_383, lastDaysAgo: nil)]
        #expect(AnalysisStallCheck.stalled(states, now: now, installedAt: daysAgo(0.5)).isEmpty)
    }

    @Test("導入時刻が不明かつ未実行なら判定しない（誤検知させない）")
    func unknownBaselineIsNotStalled() {
        let states = [state(.embeddings, pending: 100, lastDaysAgo: nil)]
        #expect(AnalysisStallCheck.stalled(states, now: now, installedAt: nil).isEmpty)
    }

    @Test("ログ行: 停滞が無ければ nil（ログを汚さない）")
    func logLineNilWhenHealthy() {
        let states = [state(.sceneTags, pending: 10, lastDaysAgo: 0.1)]
        #expect(AnalysisStallCheck.logLine(states, now: now) == nil)
    }

    @Test("ログ行: 停滞したパスと残数・放置日数を出す")
    func logLineDescribesStall() {
        let states = [state(.embeddings, pending: 43_626, lastDaysAgo: 21)]
        let line = AnalysisStallCheck.logLine(states, now: now)
        #expect(line == "analysis STALLED — embeddings(pending=43626 idle=21d)")
    }
}
