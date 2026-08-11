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

    /// 検索 1 回ぶんを本番と同じ順序で回す（ハード条件 → タグ/CLIP/字句 → 証拠ゲート）。
    private func run(_ query: SearchEvalQueries.Query,
                     corpus: SearchEvalCorpus.Corpus) async -> Set<String> {
        let now = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01（コーパスより後）
        // 解釈は決定的プレビュー（FM はテスト環境で使えない＝`SearchQualityTests` と同じ方針）。
        let saved = AIAlbumInterpreter.previewInterpretation(criteria: query.text, now: now)

        // CLIP は使わない（この層の評価ではないため）。textEmbedder なし＝タグ＋字句で解く。
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let needsFaces = AIAlbumSearcher.hasPeopleExclusion(saved.spec)
        let (members, _) = await searcher.searchWithPool(
            baseLite: corpus.photos, spec: saved.spec, now: now,
            semanticText: query.englishText,
            faceCounts: needsFaces ? corpus.faceCounts : nil,
            humanCounts: corpus.humanCounts,
            photoTags: corpus.tags,
            ocrTexts: [:],
            peopleByRefKey: nil,
            loadPage: { _, _ in [] })

        // 除外つきなら証拠ゲート（本番と同じ判定を純関数で）。
        let gated = saved.spec.allContentTerms.exclude.isEmpty
            ? members
            : AIAlbumVerificationCoordinator.evidenceGated(
                members, tags: corpus.tags, faceCounts: corpus.faceCounts, captions: corpus.captions,
                humanCounts: corpus.humanCounts,
                excludeTerms: saved.spec.allContentTerms.exclude)
        return Set(gated.map(\.id))
    }

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
        print("SEARCHEVAL: --- corpus photos=\(corpus.photos.count) "
              + "tagged=\(corpus.tags.count) faceScanned=\(corpus.faceCounts.count) "
              + "captioned=\(corpus.captions.count) ---")

        let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
            p.captureDate.map { (p.id, $0) }
        })
        for query in SearchEvalQueries.all {
            let retrieved = await run(query, corpus: corpus)
            let relevant = query.groundTruth(corpus.truth, dates: dates)
            let score = SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                retrieved: retrieved, relevant: relevant)
            if query.knownLimitation == nil { scores.append(score) }
            let limitation = query.knownLimitation.map { "  [既知の限界: \($0)]" } ?? ""
            print(String(format: "SEARCHEVAL: %-15@ excl=%@ P=%.3f R=%.3f F1=%.3f  "
                         + "retrieved=%d relevant=%d falsePositives=%d%@",
                         query.id as NSString, query.hasExclusion ? "yes" : "no ",
                         score.precision, score.recall, score.f1,
                         score.retrieved, score.relevant, score.falsePositives,
                         limitation as NSString))
        }

        let overall = SearchEvalQueries.macro(scores)
        let exclusion = SearchEvalQueries.macro(scores.filter(\.hasExclusion))
        let positive = SearchEvalQueries.macro(scores.filter { !$0.hasExclusion })
        print(String(format: "SEARCHEVAL: MACRO all       P=%.3f R=%.3f F1=%.3f",
                     overall.precision, overall.recall, overall.f1))
        print(String(format: "SEARCHEVAL: MACRO exclusion P=%.3f R=%.3f F1=%.3f  ← 実障害の指標",
                     exclusion.precision, exclusion.recall, exclusion.f1))
        print(String(format: "SEARCHEVAL: MACRO positive  P=%.3f R=%.3f F1=%.3f  ← 対照（壊していないか）",
                     positive.precision, positive.recall, positive.f1))

        // ⚠️ ここでは閾値で失敗させない（数字を台帳へ残すのが目的）。回帰の固定は
        //    `SearchEvalRegressionTests` が担当する。
        #expect(!scores.isEmpty)
    }
}
