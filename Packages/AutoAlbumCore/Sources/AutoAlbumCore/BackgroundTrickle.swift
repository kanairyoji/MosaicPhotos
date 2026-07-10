import Foundation
import MosaicSupport

/// 背景トリクル処理の共通ループ（PhotoTagger / FaceTagger / TagTagger が共用）。
/// 「バッチ供給 → 1 単位ずつ推論 → バッチごとに 1 回保存 → バッチ間スリープ」の骨格を提供する。
///
/// ⚠️ 不変条件: 停止判定は 1 単位ごと（各推論の**前**に `shouldPause` を確認）。
/// バッチ一括で確認すると、ロック解除直後の操作までの譲りが単位所要 × バッチ件数ぶん遅れる。
/// 「1 単位」は通常 1 枚。CLIP 埋め込みのみミニバッチ（≤8枚・ANE 償却で 2〜4 倍速）を単位とする。
@MainActor
enum BackgroundTrickle {

    /// バッチ確定（保存・通知）後にループを続けるかどうか。
    enum BatchOutcome {
        /// バッチ間スリープ（`betweenBatchNs`）を挟んで次バッチへ。
        case proceed
        /// スリープせず即終了（結果空＝推論に到達せずキャンセル、など）。
        case stop
    }

    /// `shouldPause` が立っている間 0.3s ずつ眠って譲る（キャンセルで抜ける）。
    /// `pausePerfLabel` を渡すと譲り待ちの発生数を PerfTrace に数える（センサー用途）。
    static func waitWhilePaused(_ shouldPause: @MainActor () -> Bool,
                                pausePerfLabel: String? = nil) async {
        while shouldPause() && !Task.isCancelled {
            if let pausePerfLabel { PerfTrace.count(pausePerfLabel) }
            try? await Task.sleep(nanoseconds: 300_000_000)   // 0.3s
        }
    }

    /// trickle ループ本体。
    /// - `nextBatch`: 次に処理する単位列を返す（**空配列で正常終了**）。todo の切り出し・動的クエリ・
    ///   尽きたときのログは呼び手がこの中で行う（各タガーで供給方法が異なるため）。
    /// - `processUnit`: 1 単位の推論。所要 ms を `unitPerfLabel` に記録する
    ///   （`unitPerfDivisor` で 1 枚あたりへ換算できる。既定 1）。
    /// - `commitBatch`: バッチ結果の保存・進捗/周期通知（save はバッチ 1 回、の置き場）。
    ///   キャンセルで途中までになった部分結果もそのまま渡す。`.stop` でスリープせず終了。
    static func run<Unit, UnitResult>(
        maxBatches: Int = .max,
        betweenBatchNs: UInt64,
        shouldPause: @MainActor () -> Bool,
        pausePerfLabel: String? = nil,
        unitPerfLabel: String,
        unitPerfDivisor: (Unit) -> Double = { _ in 1 },
        nextBatch: @MainActor (_ batchIndex: Int) async -> [Unit],
        processUnit: @MainActor (Unit) async -> UnitResult,
        commitBatch: @MainActor (_ batchIndex: Int, _ batch: [Unit], _ results: [UnitResult]) async -> BatchOutcome
    ) async {
        var batchIndex = 0
        while batchIndex < maxBatches, !Task.isCancelled {
            let batch = await nextBatch(batchIndex)
            guard !batch.isEmpty else { break }

            var results: [UnitResult] = []
            for unit in batch {
                // ⚠️ 停止判定は 1 単位ごと：各推論の前に譲る（上記の不変条件）。
                await waitWhilePaused(shouldPause, pausePerfLabel: pausePerfLabel)
                if Task.isCancelled { break }
                let tUnit = PerfTrace.nowNs()
                let result = await processUnit(unit)
                PerfTrace.count(unitPerfLabel, value: PerfTrace.msSince(tUnit) / unitPerfDivisor(unit))
                results.append(result)
            }
            if await commitBatch(batchIndex, batch, results) == .stop { break }
            // ★ バッチ間で休む：端末・ネットワーク・UI を圧迫しない trickle 処理にする。
            try? await Task.sleep(nanoseconds: betweenBatchNs)
            batchIndex += 1
        }
    }
}
