import Foundation
@testable import AutoAlbumCore

/// COCO 評価の検索実行（本番と同じ順序: ハード条件 → タグ/字句 → 証拠ゲート）。
/// 計測（`SearchEvalTests`）と回帰フロア（`SearchEvalRegressionTests`）が共用する。
enum SearchEvalRunner {
    /// 検索 1 回ぶんを本番と同じ順序で回す（ハード条件 → タグ/CLIP/字句 → 証拠ゲート）。
    static func run(_ query: SearchEvalQueries.Query,
                     corpus: SearchEvalCorpus.Corpus) async -> Set<String> {
        let now = Date(timeIntervalSince1970: 1_767_225_600)   // 2026-01-01（コーパスより後）
        // 解釈は決定的プレビュー（FM はテスト環境で使えない＝`SearchQualityTests` と同じ方針）。
        let saved = AIAlbumInterpreter.previewInterpretation(criteria: query.text, now: now,
                                                             namedPeople: corpus.namedPeople)

        // CLIP は使わない（この層の評価ではないため）。textEmbedder なし＝タグ＋字句で解く。
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let needsFaces = AIAlbumSearcher.hasPeopleExclusion(saved.spec)
        // 属性シグナル（S10）: 本番 AIAlbumService.querySignalsIfNeeded と同じ組み立て。
        let signals = QuerySignals(
            smileCounts: corpus.smileCounts,
            humanCounts: corpus.humanCounts,
            aesthetics: corpus.aesthetics,
            aestheticFloor: PhotoQuality.adaptiveThreshold(scores: Array(corpus.aesthetics.values)))
        let (members, _) = await searcher.searchWithPool(
            baseLite: corpus.photos, spec: saved.spec, now: now,
            semanticText: query.englishText,
            faceCounts: needsFaces ? corpus.faceCounts : nil,
            humanCounts: corpus.humanCounts,
            photoTags: corpus.tags,
            ocrTexts: [:],
            peopleByRefKey: nil,
            signals: signals,
            loadPage: { _, _ in [] })

        // 除外つきなら証拠ゲート（本番と同じ判定を純関数で）。
        let gated = saved.spec.allContentTerms.exclude.isEmpty
            ? members
            : AIAlbumVerificationCoordinator.evidenceGated(
                members, tags: corpus.tags, faceCounts: corpus.faceCounts,
                humanCounts: corpus.humanCounts,
                excludeTerms: saved.spec.allContentTerms.exclude)
        return Set(gated.map(\.id))
    }

}
