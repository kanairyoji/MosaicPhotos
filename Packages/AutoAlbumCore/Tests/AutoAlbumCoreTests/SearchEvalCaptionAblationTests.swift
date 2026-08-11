import Foundation
import Testing
@testable import AutoAlbumCore

/// VLM キャプションの**検索への寄与**を網羅率アブレーションで測る（ADR-104 の運用）。
///
/// 動機: キャプション生成は最も重い AI 処理（SmolVLM 500M・1 枚数十秒・モデル 877MB）なのに、
/// 検索パイプラインでの役割は「証拠ゲートの存在 1 票」だけ（ランキング・字句照合には不参加）。
/// 廃止/縮小の判断材料として、網羅率 0% / 1%（実機実測）/ 100%（理想上限）で
/// 全クエリの検出性能がどう変わるかを測る。
///
/// 実行: `cd Packages/AutoAlbumCore && swift test --filter CaptionAblation`
/// データ未取得ならスキップ（`scripts/fetch_search_eval_datasets.sh`）。
@Suite("SearchEvalCaptionAblation (キャプション網羅率の寄与)")
struct SearchEvalCaptionAblationTests {

    @Test("キャプション網羅率 0% / 1% / 100% で全クエリを比較する")
    func captionCoverageAblation() async throws {
        guard SearchEvalCorpus.isAvailable else { return }
        var results: [(label: String, p: Double, r: Double, f1: Double,
                       exclP: Double, exclR: Double)] = []
        for (label, captions) in [("0%(廃止)", 0.0), ("1%(実機)", 0.01), ("100%(上限)", 1.0)] {
            var coverage = SearchEvalCorpus.Coverage.device
            coverage.captions = captions
            let corpus = try SearchEvalCorpus.load(coverage: coverage)
            let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
                p.captureDate.map { (p.id, $0) }
            })
            var scores: [SearchEvalQueries.Score] = []
            var exclusionScores: [SearchEvalQueries.Score] = []
            for query in SearchEvalQueries.all where query.knownLimitation == nil {
                let retrieved = await SearchEvalRunner.run(query, corpus: corpus)
                let relevant = query.groundTruth(corpus: corpus, dates: dates)
                let score = SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                    retrieved: retrieved, relevant: relevant)
                scores.append(score)
                if query.hasExclusion { exclusionScores.append(score) }
            }
            let all = SearchEvalQueries.macro(scores)
            let excl = SearchEvalQueries.macro(exclusionScores)
            results.append((label, all.precision, all.recall, all.f1, excl.precision, excl.recall))
            print(String(format: "CAPTIONABL: %-10@ 全体 P=%.3f R=%.3f F1=%.3f | 除外つき P=%.3f R=%.3f",
                         label as NSString, all.precision, all.recall, all.f1,
                         excl.precision, excl.recall))
        }
        // 判断材料の要約: 0% と 1%（実機）の差が事実上ゼロなら、現状の実機では
        // キャプションは検索に寄与していない（表示専用）ことが確定する。
        if let zero = results.first, let device = results.dropFirst().first {
            let delta = abs(device.f1 - zero.f1)
            print(String(format: "CAPTIONABL: Δ(1%%−0%%) F1=%.4f（実機網羅率での寄与）", delta))
        }
    }
}
