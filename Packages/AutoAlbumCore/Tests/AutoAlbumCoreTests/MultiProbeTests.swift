import Foundation
import Testing
@testable import AutoAlbumCore

/// マルチプローブ（ADR-35）: 意味採点を「主フレーズ＋FM 言い換えプローブの max-over-probes」に
/// することで、言い換え表現の取りこぼし（ベースライン計測で memberR 0.61〜0.68）を回収する。
@Suite("Multi-probe semantic scoring (ADR-35)")
struct MultiProbeTests {
    private let now = Date()

    private func photo(_ id: String, clip: [Float]) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: now, latitude: nil, longitude: nil,
                      placeName: nil, clipVector: ClipMath.encode(clip))
    }

    private func pagedLoader(_ photos: [EnrichedPhoto]) -> (Int, Int) async -> [(refKey: String, clipVector: Data)] {
        let embedded = photos.compactMap { ph in ph.clipVector.map { (ph.id, $0) } }.sorted { $0.0 < $1.0 }
        return { offset, limit in embedded.dropFirst(offset).prefix(limit).map { (refKey: $0.0, clipVector: $0.1) } }
    }

    private struct MappingEmbedder: TextEmbedder {
        let map: [String: [Float]]
        var isAvailable: Bool { true }
        func embed(_ text: String) async -> [Float]? { map[text] }
    }

    @Test("semanticScore は max-over-probes（どれかの言い回しに近ければ拾う）")
    func semanticScoreTakesMaxOverProbes() {
        let q = QueryEmbedder.QueryVectors(positives: [[1, 0], [0, 1]], negatives: [])
        // 主フレーズには遠い（0.1）がプローブには近い（0.99）→ max を採る
        let score = QueryEmbedder.semanticScore(q, photoVector: [0.1, 0.99])
        #expect(score != nil && score! > 0.9)
    }

    @Test("semanticScore の除外対比は max-positive と比較（相対判定のみ）")
    func semanticScoreContrastUsesMaxPositive() {
        let q = QueryEmbedder.QueryVectors(positives: [[1, 0], [0, 1]], negatives: [[0.6, 0.6]])
        // neg≈0.85 < プローブ側 pos≈0.99 → 残る（主フレーズだけなら neg 優位で落ちていた）
        #expect(QueryEmbedder.semanticScore(q, photoVector: [0.1, 0.99]) != nil)
        // 両 positive より neg に近い → 落ちる
        #expect(QueryEmbedder.semanticScore(q, photoVector: [0.7, 0.7]) == nil)
    }

    @Test("プローブが言い換えの取りこぼしを回収する（プローブ無しでは margin 外→有りで member）")
    func probesRescueParaphraseMisses() async {
        let embedder = MappingEmbedder(map: [
            "church": [1, 0],
            "cathedral": [0, 1],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("mainHit", clip: [1, 0.02]),       // 主フレーズに一致（score≈1.0）
                      photo("paraHit", clip: [0.08, 0.99])]    // 言い換え側にのみ一致（main 0.08）
        let spec = QuerySpec(clauses: [QueryClause([.content(["church"])])])

        // プローブ無し: paraHit は top(1.0) − margin(0.06) の外 → 取りこぼす
        let without = await searcher.search(baseLite: photos, spec: spec, now: now,
                                            semanticText: "", loadPage: pagedLoader(photos))
        #expect(!without.contains { PhotoRef.decode($0.id)?.localIdentifier == "paraHit" })

        // プローブ有り: max-over-probes で paraHit≈0.99 → margin 内 → member に入る
        let with = await searcher.search(baseLite: photos, spec: spec, now: now,
                                         semanticText: "", probes: ["cathedral"],
                                         loadPage: pagedLoader(photos))
        #expect(with.contains { PhotoRef.decode($0.id)?.localIdentifier == "paraHit" })
        #expect(with.contains { PhotoRef.decode($0.id)?.localIdentifier == "mainHit" })
    }

    @Test("除外語があるときはプローブを使わない（対比が弱まる回帰の防止）")
    func exclusionDisablesProbes() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0],
            "mountain view": [0, 1],
            QueryEmbedder.excludePrompt("people"): [0.3, 0.8],
        ])
        // 除外あり: プローブは埋め込まれない（positives は主フレーズ 1 本のみ）
        let q = await QueryEmbedder(textEmbedder: embedder)
            .embed(phrase: "landscape", probes: ["mountain view"], excludeTerms: ["people"])
        #expect(q?.positives.count == 1)
        // 実障害の再現: 人物入り写真 v は主フレーズ pos(0.28) < neg(0.75) → 落ちる。
        // もしプローブが有効だと max-pos(≈0.8) > neg となり素通りしていた。
        let v: [Float] = [0.28, 0.75]
        #expect(QueryEmbedder.semanticScore(q!, photoVector: v) == nil)

        // 除外なし: プローブは通常どおり有効。
        let q2 = await QueryEmbedder(textEmbedder: embedder)
            .embed(phrase: "landscape", probes: ["mountain view"], excludeTerms: [])
        #expect(q2?.positives.count == 2)
    }

    @Test("embed はプローブの空・主フレーズ重複を捨て、最大4本に丸める")
    func embedSanitizesProbes() async {
        let embedder = MappingEmbedder(map: [
            "church": [1, 0], "a": [0, 1], "b": [1, 1], "c": [0.5, 1], "d": [1, 0.5], "e": [0, 0.5],
        ])
        let q = await QueryEmbedder(textEmbedder: embedder)
            .embed(phrase: "church", probes: ["", "CHURCH", "a", "b", "c", "d", "e"], excludeTerms: [])
        // 主 1 本＋（空/重複を除いた）プローブ最大 4 本 → prefix(4) は ["", "CHURCH", "a", "b"] から
        // 有効な a, b の 2 本
        #expect(q?.positives.count == 3)
    }
}

/// レキシコンの接地プレビュー/逆引き API（ADR-37・コンポーザーのサジェスト/色付きチップ用）。
@Suite("JapaneseVisualLexicon suggestion APIs (ADR-37)")
struct LexiconSuggestionTests {
    @Test("groundedPairs は（日本語, 英語代表）対を返す")
    func groundedPairsReturnsJpEnPairs() {
        let pairs = JapaneseVisualLexicon.groundedPairs(in: "沖縄の海と夕日の写真")
        let jp = pairs.map(\.japanese)
        #expect(jp.contains("海"))
        #expect(jp.contains("夕日"))
        #expect(pairs.first { $0.japanese == "海" }?.english == "beach")
    }

    @Test("japaneseLabel はタグ→日本語代表語（対応なしは nil）")
    func japaneseLabelReverseLookup() {
        #expect(JapaneseVisualLexicon.japaneseLabel(forTag: "beach") == "海")
        #expect(JapaneseVisualLexicon.japaneseLabel(forTag: "dog") == "犬")
        #expect(JapaneseVisualLexicon.japaneseLabel(forTag: "sunset") == "夕日")
        #expect(JapaneseVisualLexicon.japaneseLabel(forTag: "manhole") == nil)
    }
}
