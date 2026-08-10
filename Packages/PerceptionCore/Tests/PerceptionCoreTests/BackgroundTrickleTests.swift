import Foundation
import Testing
@testable import PerceptionCore

/// 背景トリクルの譲り挙動（ADR-79: 譲り開始フックで重いモデルを解放する）。
@Suite("BackgroundTrickle")
@MainActor
struct BackgroundTrickleTests {

    /// 呼び出し回数を数えるだけの可変ホルダ（@MainActor 上で使う）。
    @MainActor
    final class Counter {
        var pauseChecks = 0
        var pauseBegins = 0
        var processed: [Int] = []
    }

    @Test("譲りに入ったら onPauseBegin が 1 回だけ呼ばれる（待機中は繰り返さない）")
    func pauseBeginFiresOnce() async {
        let c = Counter()
        // 最初の 3 回は「譲れ」、以降は再開。
        await BackgroundTrickle.waitWhilePaused({
            c.pauseChecks += 1
            return c.pauseChecks <= 3
        }, onPauseBegin: { c.pauseBegins += 1 })

        #expect(c.pauseBegins == 1)      // 0.3s ごとの待機中に何度も解放を呼ばない
        #expect(c.pauseChecks == 4)      // 4 回目で false → 抜ける
    }

    @Test("譲りが発生しなければ onPauseBegin は呼ばれない")
    func pauseBeginNotFiredWhenRunning() async {
        let c = Counter()
        await BackgroundTrickle.waitWhilePaused({ false },
                                                onPauseBegin: { c.pauseBegins += 1 })
        #expect(c.pauseBegins == 0)
    }

    /// ADR-83: バッチの素材（クラウドサムネ）をまとめて先行取得するフック。
    /// 1 枚ずつ取ると往復が推論と直列に並び、AI 処理時間の 85〜90% を占めていた。
    @Test("run: warmBatch はバッチ取得直後に、そのバッチ全体で 1 回呼ばれる")
    func warmBatchCalledOncePerBatch() async {
        let c = Counter()
        var warmed: [[Int]] = []
        var order: [String] = []
        await BackgroundTrickle.run(
            maxBatches: 2,
            betweenBatchNs: 0,
            shouldPause: { false },
            unitPerfLabel: "test.unitMs",
            warmBatch: { batch in
                warmed.append(batch)
                order.append("warm")
            },
            nextBatch: { index in index == 0 ? [1, 2, 3] : [] },
            processUnit: { unit in
                order.append("process")
                c.processed.append(unit)
                return unit
            },
            commitBatch: { _, _, _ in .stop })

        #expect(warmed == [[1, 2, 3]])                       // バッチ丸ごと 1 回だけ
        #expect(order.first == "warm")                       // 推論より**先**に呼ばれる
        #expect(c.processed == [1, 2, 3])
    }

    @Test("run: warmBatch 未指定でも従来どおり動く（既定 nil）")
    func warmBatchIsOptional() async {
        let c = Counter()
        await BackgroundTrickle.run(
            maxBatches: 1,
            betweenBatchNs: 0,
            shouldPause: { false },
            unitPerfLabel: "test.unitMs",
            nextBatch: { index in index == 0 ? [7] : [] },
            processUnit: { unit in c.processed.append(unit); return unit },
            commitBatch: { _, _, _ in .stop })
        #expect(c.processed == [7])
    }

    @Test("run: 譲りは 1 単位ごとに確認され、フックは譲りのたびに 1 回立つ")
    func runFiresPauseHookPerPause() async {
        let c = Counter()
        var pauseNext = false
        await BackgroundTrickle.run(
            maxBatches: 1,
            betweenBatchNs: 0,
            shouldPause: {
                // 各単位の前に 1 度だけ譲る（次の確認では false に戻す）。
                defer { pauseNext = false }
                return pauseNext
            },
            onPauseBegin: { c.pauseBegins += 1 },
            unitPerfLabel: "test.unitMs",
            nextBatch: { index in index == 0 ? [1, 2, 3] : [] },
            processUnit: { unit in
                c.processed.append(unit)
                pauseNext = true      // 次の単位の前に 1 回譲らせる
                return unit
            },
            commitBatch: { _, _, _ in .stop })

        #expect(c.processed == [1, 2, 3])
        // 1 単位目は譲らず、2・3 単位目の前で 1 回ずつ譲る。
        #expect(c.pauseBegins == 2)
    }

    // MARK: - 譲り待ちの上限（ADR-95）

    /// 実機 diagnostics-38 の回帰: ゲートが閉じたまま眠り続けた bgfill が実行中フラグを
    /// 14 分間握り、その間に開いた夜間 BGTask 窓（77 秒）もキャプション窓も
    /// 「already tagging/embedding」で捨てられていた。眠るなら**フラグを手放して**眠る。
    @Test("譲りが上限を超えたら諦めて true を返す（実行中フラグを解放するため）")
    func waitGivesUpAfterMaxPause() async {
        let c = Counter()
        let gaveUp = await BackgroundTrickle.waitWhilePaused({
            c.pauseChecks += 1
            return true              // 永遠に譲れ＝ゲートが開かない
        }, maxPauseNs: 900_000_000)  // 0.3s × 3 回ぶん
        #expect(gaveUp, "上限を超えても諦めずに待ち続けている")
        #expect(c.pauseChecks <= 6, "上限を大きく超えて待っている: \(c.pauseChecks)")
    }

    @Test("ゲートが開けば諦めない（false を返して通常どおり続行）")
    func waitDoesNotGiveUpWhenGateOpens() async {
        let c = Counter()
        let gaveUp = await BackgroundTrickle.waitWhilePaused({
            c.pauseChecks += 1
            return c.pauseChecks <= 2
        }, maxPauseNs: 60_000_000_000)
        #expect(!gaveUp)
    }

    @Test("run: 譲り待ちが上限を超えたらループを畳む（バッチを回し続けない）")
    func runStopsWhenPauseExceedsLimit() async {
        let c = Counter()
        var committed = 0
        await BackgroundTrickle.run(
            betweenBatchNs: 0,
            shouldPause: { true },              // ずっと閉じたまま
            unitPerfLabel: "test.unit",
            maxPauseNs: 600_000_000,            // 0.6s で諦める
            nextBatch: { batch in batch < 5 ? [batch] : [] },
            processUnit: { c.processed.append($0) },
            commitBatch: { _, _, _ in committed += 1; return .proceed })
        #expect(c.processed.isEmpty, "譲り中なのに推論が走っている")
        // 諦めた 1 バッチぶんだけ commit（部分結果の保存）が呼ばれてループが終わる。
        #expect(committed == 1, "ループを畳まずバッチを回し続けている（commit=\(committed)）")
    }
}
