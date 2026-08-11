import Foundation
import Testing
@testable import AutoAlbumCore

/// 検索品質の計測（手動実行専用・データセットが無ければスキップ）。
///
/// 目的: 「人が写っていない風景に人が混ざる」等の**除外条件の precision** を、正解付きで測る。
/// 既存の `SearchQualityTests`（Imagenette・Recall@k）は肯定側の認識を測るもので、
/// 人物の正解ラベルが無く除外を評価できなかった。ここは補完であって置き換えではない。
///
/// 何を測って**いない**か（重要）: CLIP/Vision の認識精度は測らない。台帳は COCO の正解から
/// 合成するので、ここで出る数字は**解釈→接地→照合→証拠ゲート**の層の性能である。
/// 層を分離してあるので、改修の段階ごとの寄与を切り分けられる。
///
/// 実行:
/// ```
/// scripts/fetch_search_eval_datasets.sh          # 初回のみ（COCO ラベル・約46MB）
/// cd Packages/AutoAlbumCore && swift test --filter SearchEval
/// ```
/// 出力は `SEARCHEVAL:` 行。台帳は `docs/architecture-note/records/search-quality.md`。
@Suite("SearchEval (COCO・除外条件の precision)")
struct SearchEvalTests {

    @Test("COCO で除外条件つき検索の precision/recall を測る")
    func measure() async throws {
        // データセットが無い環境（CI・他の開発機）では**失敗させずに抜ける**。
        // 手動実行専用の計測なので、取得していないことは異常ではない。
        guard SearchEvalCorpus.isAvailable else {
            print("SEARCHEVAL: skipped — データセット未取得"
                  + "（scripts/fetch_search_eval_datasets.sh を実行）")
            return
        }
        let corpus = try SearchEvalCorpus.load(coverage: .device)

        var scores: [SearchEvalQueries.Score] = []
        var byCategory: [String: [SearchEvalQueries.Score]] = [:]
        print("SEARCHEVAL: --- corpus photos=\(corpus.photos.count) "
              + "tagged=\(corpus.tags.count) faceScanned=\(corpus.faceCounts.count) "
              + "---")

        let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
            p.captureDate.map { (p.id, $0) }
        })
        for query in SearchEvalQueries.all {
            let retrieved = await SearchEvalRunner.run(query, corpus: corpus)
            let relevant = query.groundTruth(corpus: corpus, dates: dates)
            let score = SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                retrieved: retrieved, relevant: relevant)
            if query.knownLimitation == nil {
                scores.append(score)
                byCategory[query.category, default: []].append(score)
            }
            let limitation = query.knownLimitation.map { "  [既知の限界: \($0)]" } ?? ""
            print(String(format: "SEARCHEVAL: %-15@ excl=%@ P=%.3f R=%.3f F1=%.3f  "
                         + "retrieved=%d relevant=%d falsePositives=%d%@",
                         query.id as NSString, query.hasExclusion ? "yes" : "no ",
                         score.precision, score.recall, score.f1,
                         score.retrieved, score.relevant, score.falsePositives,
                         limitation as NSString))
        }

        let overall = SearchEvalQueries.macro(scores)
        print(String(format: "SEARCHEVAL: MACRO all (%d queries)  P=%.3f R=%.3f F1=%.3f",
                     scores.count, overall.precision, overall.recall, overall.f1))
        // カテゴリ別（S11: 100 本規模の分析はカテゴリ単位で読む）。
        for (category, catScores) in byCategory.sorted(by: { $0.key < $1.key }) {
            let m = SearchEvalQueries.macro(catScores)
            let worst = catScores.min { $0.f1 < $1.f1 }
            print(String(format: "SEARCHEVAL: MACRO %-11@ (%2d) P=%.3f R=%.3f F1=%.3f  worst=%@ (%.3f)",
                         category as NSString, catScores.count, m.precision, m.recall, m.f1,
                         (worst?.queryID ?? "-") as NSString, worst?.f1 ?? 0))
        }

        // ⚠️ ここでは閾値で失敗させない（数字を台帳へ残すのが目的）。回帰の固定は
        //    `SearchEvalRegressionTests` が担当する。
        #expect(!scores.isEmpty)
    }

    /// 属性クエリの**網羅率天井**: 索引が全件済んだ場合の性能（配線の正しさと網羅率の限界を分離）。
    /// 実機の数字（measure・顔 11%）が低いのは配線の欠陥でなく索引の進行度であることを示す。
    @Test("属性クエリの天井（索引 100% 時）")
    func attributeCeiling() async throws {
        guard SearchEvalCorpus.isAvailable else { return }
        let corpus = try SearchEvalCorpus.load(coverage: .complete)
        let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
            p.captureDate.map { (p.id, $0) }
        })
        for query in SearchEvalQueries.all
        where query.requireSmiling || query.requireBeautiful || query.requireChild {
            let retrieved = await SearchEvalRunner.run(query, corpus: corpus)
            let relevant = query.groundTruth(corpus: corpus, dates: dates)
            let score = SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                retrieved: retrieved, relevant: relevant)
            print(String(format: "SEARCHEVAL-CEIL: %-15@ P=%.3f R=%.3f F1=%.3f (索引100%%時)",
                         query.id as NSString, score.precision, score.recall, score.f1))
        }
    }
}
