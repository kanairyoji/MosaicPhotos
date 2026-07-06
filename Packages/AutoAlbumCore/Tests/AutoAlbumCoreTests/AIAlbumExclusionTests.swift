import Foundation
import Testing
@testable import AutoAlbumCore

/// 除外条件（「人が写っていない」等）の対比採点と顔実測フィルタ。
/// CLIP は文中の否定（"without people"）を理解しないため、(1) 除外語は**別ベクトルとの対比**
/// （肯定より近い／しきい値超で落とす）、(2) 人系の除外は**顔スキャンの実測**（faceCount）で
/// ハード除外、の 2 段で実現する（設計の経緯は事例参照）。
@Suite("AIAlbum exclusion (contrast + faceCounts)")
struct AIAlbumExclusionTests {
    private let now = Date()

    private func photo(_ id: String, clip: [Float]? = nil) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: now, latitude: nil, longitude: nil,
                      placeName: "Tokyo", clipVector: clip.map { ClipMath.encode($0) })
    }

    private func pagedLoader(_ photos: [EnrichedPhoto]) -> (Int, Int) async -> [(refKey: String, clipVector: Data)] {
        let embedded = photos.compactMap { ph in ph.clipVector.map { (ph.id, $0) } }.sorted { $0.0 < $1.0 }
        return { offset, limit in embedded.dropFirst(offset).prefix(limit).map { (refKey: $0.0, clipVector: $0.1) } }
    }

    /// テキストごとに異なるベクトルを返す埋め込みスタブ（肯定と除外を区別するため）。
    private struct MappingEmbedder: TextEmbedder {
        let map: [String: [Float]]
        var isAvailable: Bool { true }
        func embed(_ text: String) async -> [Float]? { map[text] }
    }

    /// 「landscape・人以外」: 除外概念（people）に肯定より近い写真は落ちる。
    @Test("除外語は対比で落とす（肯定より除外に近い写真を除外）")
    func contrastDropsCloserToExcluded() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0],
            AIAlbumSearcher.excludePrompt("people"): [0, 1],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("scenery", clip: [1, 0.05]),      // pos≈1.0, neg≈0.05 → 残る
                      photo("withperson", clip: [0.6, 0.8])]  // pos=0.6, neg=0.8 → neg>pos で落ちる
        let spec = QuerySpec(clauses: [QueryClause([.content(["landscape"]), .not(.content(["people"]))])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "Landscape photos without people",
                                           loadPage: pagedLoader(photos))
        #expect(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier } == ["scenery"])
    }

    /// CLIP 対比は相対判定のみ（絶対閾値は廃止＝ADR-24）。肯定に近い写真は除外類似が
    /// あっても残り、精度は証拠ゲート（タグ/顔/キャプション）が担う。
    @Test("CLIP 対比は相対のみ（肯定優位なら残る・絶対閾値は無い）")
    func contrastIsRelativeOnly() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0],
            AIAlbumSearcher.excludePrompt("people"): [0, 1],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("clean", clip: [1, 0.1]),
                      photo("faintPerson", clip: [1, 0.25])]   // neg≈0.24 だが pos≈0.97 優位 → 残る
        let spec = QuerySpec(clauses: [QueryClause([.content(["landscape"]), .not(.content(["people"]))])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "",
                                           loadPage: pagedLoader(photos))
        #expect(Set(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier }) == ["clean", "faintPerson"])
    }

    /// 証拠ゲート: タグ・顔実測・キャプションのいずれも無い写真は除外つきアルバムに入れない。
    @Test("evidenceGated: 証拠ゼロの写真は落ち、いずれかがあれば残る")
    func evidenceGateRules() {
        let a = photo("tagged"), b = photo("faced"), c = photo("captioned"), d = photo("nothing")
        let gated = AIAlbumSearcher.evidenceGated(
            [a, b, c, d],
            tags: [a.id: ["landscape"]],
            faceCounts: [b.id: 0],
            captions: [c.id: "A beach."])
        #expect(Set(gated.map(\.id)) == Set([a.id, b.id, c.id]))
        // 空キャプション・空タグは証拠にならない。
        let gated2 = AIAlbumSearcher.evidenceGated([d], tags: [d.id: []], faceCounts: [:],
                                                   captions: [d.id: ""])
        #expect(gated2.isEmpty)
    }

    /// 顔スキャンの実測（faceCounts）: 顔がある写真はハード除外、未スキャンは CLIP に任せて残す。
    @Test("faceCounts: 顔実測>0 は除外・0 は残す・未スキャンは通す")
    func faceCountsHardFilter() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0],
            AIAlbumSearcher.excludePrompt("people"): [0, 1],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("hasFace", clip: [1, 0]),
                      photo("noFace", clip: [1, 0]),
                      photo("unscanned", clip: [1, 0])]
        let spec = QuerySpec(clauses: [QueryClause([.content(["landscape"]), .not(.content(["people"]))])])
        let faceCounts = [PhotoRef.local("hasFace").encoded: 2,
                          PhotoRef.local("noFace").encoded: 0]
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "", faceCounts: faceCounts,
                                           loadPage: pagedLoader(photos))
        #expect(Set(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier }) == ["noFace", "unscanned"])
    }

    /// 除外があるとき、肯定側の埋め込みは全文（否定入り）でなく include 語だけを使う。
    @Test("除外があるとき肯定側フレーズは include 語だけ（否定入り全文を埋め込まない）")
    func positivePhraseAvoidsNegatedSentence() async {
        final class RecordingEmbedder: TextEmbedder, @unchecked Sendable {
            var texts: [String] = []
            var isAvailable: Bool { true }
            func embed(_ text: String) async -> [Float]? { texts.append(text); return [1, 0] }
        }
        let embedder = RecordingEmbedder()
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("a", clip: [1, 0])]
        let spec = QuerySpec(clauses: [QueryClause([.content(["landscape"]), .not(.content(["people"]))])])
        _ = await searcher.search(baseLite: photos, spec: spec, now: now,
                                  semanticText: "Landscape photos without people",
                                  loadPage: pagedLoader(photos))
        #expect(embedder.texts.first == "landscape")   // 否定入り全文ではない
        #expect(embedder.texts.contains(AIAlbumSearcher.excludePrompt("people")))
    }

    /// 意味採用が 0 件で base へフォールバックするときも、除外で落とした写真は復活させない。
    /// （実障害: negFilter dropped=370 なのに result=388＝生 base が返り人物写真が混入した）
    @Test("フォールバック（意味0件→base）でも除外済みは復活しない")
    func fallbackRespectsExclusion() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0, 0],
            AIAlbumSearcher.excludePrompt("people"): [0, 1, 0],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        // weak: pos≈0.15（floor 0.20 未満＝意味採用されない）・neg≈0.05（除外もされない）
        // personShot: neg≈0.99 → 除外で落ちる
        let photos = [photo("weak", clip: [0.15, 0.05, 0.99]),
                      photo("personShot", clip: [0.1, 0.99, 0.05])]
        // place ハードあり＝フォールバックは base を返す経路に入る。
        let spec = QuerySpec(clauses: [QueryClause([.place(["tokyo"]),
                                                    .content(["landscape"]),
                                                    .not(.content(["people"]))])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "",
                                           loadPage: pagedLoader(photos))
        // 意味 0 件 → base フォールバックだが、personShot（除外済み）は含まれない。
        #expect(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier } == ["weak"])
    }

    /// P1: シーンタグ（Vision 分類）とクエリ語の一致。
    @Test("tagHits: 完全/部分一致（ci）を数える")
    func tagHitCounting() {
        #expect(AIAlbumSearcher.tagHits(["beach", "sunset", "outdoor"], terms: ["beach"]) == 1)
        #expect(AIAlbumSearcher.tagHits(["beach", "sunset"], terms: ["Beach", "sunset"]) == 2)
        #expect(AIAlbumSearcher.tagHits(["sandy_beach"], terms: ["beach"]) == 1)      // タグ ⊃ 語
        #expect(AIAlbumSearcher.tagHits(["dog"], terms: ["dogs"]) == 1)               // 語 ⊃ タグ
        #expect(AIAlbumSearcher.tagHits(["indoor"], terms: ["beach"]) == 0)
        #expect(AIAlbumSearcher.tagHits([], terms: ["beach"]) == 0)
    }

    @Test("タグ一致は意味0件でもメンバーに入る（タグ＝閾値レスの一次ランキング）")
    func tagMatchRanksWithoutSemantics() async {
        // 埋め込み無し（textEmbedder nil）でもタグ一致でヒットする。
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let photos = [photo("beachShot", clip: nil), photo("indoorShot", clip: nil)]
        let spec = QuerySpec(clauses: [QueryClause([.content(["beach"])])])
        let tags = [PhotoRef.local("beachShot").encoded: ["beach", "outdoor"],
                    PhotoRef.local("indoorShot").encoded: ["indoor", "room"]]
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "beach", photoTags: tags,
                                           loadPage: pagedLoader(photos))
        #expect(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier } == ["beachShot"])
    }

    @Test("除外語はタグの離散一致でもハード除外する")
    func tagExclusionHardFilters() async {
        let embedder = MappingEmbedder(map: [
            "landscape": [1, 0],
            AIAlbumSearcher.excludePrompt("people"): [0, 1],
        ])
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("clean", clip: [1, 0.05]), photo("tagged", clip: [1, 0.05])]
        let spec = QuerySpec(clauses: [QueryClause([.content(["landscape"]), .not(.content(["people"]))])])
        let tags = [PhotoRef.local("tagged").encoded: ["people", "outdoor"]]   // タグに people
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "", photoTags: tags,
                                           loadPage: pagedLoader(photos))
        #expect(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier } == ["clean"])
    }

    /// フレーズ無し（翻訳保留等）でハード条件も無いとき、全写真を返さない（実障害: 68,512 枚アルバム）。
    @Test("フレーズ無し＋ハード無しは空（全写真アルバムを作らない）")
    func noPhraseNoHardReturnsEmpty() async {
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let photos = [photo("a", clip: [1, 0]), photo("b", clip: [0, 1])]
        let spec = QuerySpec(clauses: [])   // 解釈全滅＋翻訳保留の状態
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "", loadPage: pagedLoader(photos))
        #expect(result.isEmpty)
    }

    /// 人系の除外語の判定（顔実測を使うかどうか）。
    @Test("hasPeopleExclusion は人系の語だけ true")
    func peopleExclusionDetection() {
        func spec(excluding term: String) -> QuerySpec {
            QuerySpec(clauses: [QueryClause([.not(.content([term]))])])
        }
        #expect(AIAlbumSearcher.hasPeopleExclusion(spec(excluding: "people")))
        #expect(AIAlbumSearcher.hasPeopleExclusion(spec(excluding: "person")))
        #expect(AIAlbumSearcher.hasPeopleExclusion(spec(excluding: "children")))
        #expect(!AIAlbumSearcher.hasPeopleExclusion(spec(excluding: "cars")))
        #expect(!AIAlbumSearcher.hasPeopleExclusion(spec(excluding: "text")))
        #expect(!AIAlbumSearcher.hasPeopleExclusion(QuerySpec(clauses: [QueryClause([.content(["people"])])])))   // include は対象外
    }
}
