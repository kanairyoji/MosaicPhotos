import Foundation
import Testing
@testable import AutoAlbumCore

/// 検索品質の**回帰フロア**（S12・ADR-104 の運用を機械化）。
///
/// 計測ハーネス（`SearchEvalTests` / `SearchEvalCaltechTests`）は数字を台帳へ残すのが役目で
/// 失敗しない。こちらは**下がってはいけない下限**を固定する＝検索まわりの変更がカテゴリ単位の
/// 性能を黙って壊したら、このテストが落ちる。
///
/// フロアは現状値（2026-08-11・台帳参照）から **-0.03 の余裕**を持たせた値。
/// 意図的にトレードオフを取る変更でフロアを割る場合は、台帳に理由を書いてフロアを更新する。
/// データセット未取得の環境ではスキップ（CI 安全）。
@Suite("SearchEvalRegression (カテゴリ別フロア)")
struct SearchEvalRegressionTests {

    /// カテゴリ → F1 フロア（現状値 − 0.03）。
    /// attribute は笑顔（網羅率 11% 由来の R）を含むため低い（現状 0.650）。
    private static let cocoFloors: [String: Double] = [
        "subject": 0.89, "exclusion": 0.90, "conjunction": 0.89, "date": 0.90,
        "attribute": 0.62, "phrase": 0.78, "en": 0.77, "count": 0.89,
        "robust": 0.89, "specificity": 0.97,
    ]

    @Test("COCO: カテゴリ別マクロ F1 がフロアを割らない")
    func cocoCategoryFloors() async throws {
        guard SearchEvalCorpus.isAvailable else { return }
        let corpus = try SearchEvalCorpus.load(coverage: .device)
        let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
            p.captureDate.map { (p.id, $0) }
        })
        var byCategory: [String: [SearchEvalQueries.Score]] = [:]
        for query in SearchEvalQueries.all where query.knownLimitation == nil {
            let retrieved = await SearchEvalRunner.run(query, corpus: corpus)
            let relevant = query.groundTruth(corpus: corpus, dates: dates)
            byCategory[query.category, default: []].append(
                SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                        retrieved: retrieved, relevant: relevant))
        }
        for (category, floor) in Self.cocoFloors.sorted(by: { $0.key < $1.key }) {
            guard let scores = byCategory[category] else {
                Issue.record(Comment(rawValue: "カテゴリ \(category) のクエリが無い（クエリ集の再編で消えた？）"))
                continue
            }
            let f1 = SearchEvalQueries.macro(scores).f1
            #expect(f1 >= floor,
                    "カテゴリ \(category) の F1 がフロアを割った: \(String(format: "%.3f", f1)) < \(floor)。意図的なトレードオフなら台帳に理由を書いてフロアを更新する")
        }
    }

    /// 全体の precision フロア。**「混ざらない」はこのシステムの第一の約束**（ADR-100）。
    @Test("COCO: 全体 precision が 0.97 を割らない")
    func cocoPrecisionFloor() async throws {
        guard SearchEvalCorpus.isAvailable else { return }
        let corpus = try SearchEvalCorpus.load(coverage: .device)
        let dates = Dictionary(uniqueKeysWithValues: corpus.photos.compactMap { p in
            p.captureDate.map { (p.id, $0) }
        })
        var scores: [SearchEvalQueries.Score] = []
        for query in SearchEvalQueries.all where query.knownLimitation == nil {
            let retrieved = await SearchEvalRunner.run(query, corpus: corpus)
            let relevant = query.groundTruth(corpus: corpus, dates: dates)
            scores.append(SearchEvalQueries.score(queryID: query.id, hasExclusion: query.hasExclusion,
                                                  retrieved: retrieved, relevant: relevant))
        }
        let p = SearchEvalQueries.macro(scores).precision
        #expect(p >= 0.97, "全体 precision がフロアを割った: \(String(format: "%.3f", p))")
    }
}
