import Foundation
import Testing
@testable import AutoAlbumCore

/// LLM 出力の防御的サニタイズ（実障害2件＝例語オウム返し・"any" プレースホルダ・include/exclude 衝突）。
@Suite("QuerySpecSanitizer")
struct QuerySpecSanitizerTests {

    @Test("プレースホルダ語（any/none 等）は place/people から除去し、空になれば条件ごと消す")
    func dropsPlaceholders() {
        let spec = QuerySpec(clauses: [QueryClause([
            .place(["any"]),
            .people(["Any", "none"]),
            .content(["landscape"]),
        ])])
        let out = QuerySpecSanitizer.sanitize(spec)
        #expect(out.clauses.count == 1)
        #expect(out.clauses[0].conditions == [.content(["landscape"])])
    }

    @Test("place/people の項数が多すぎる（カタログ丸写し）は条件ごと捨てる")
    func dropsCatalogDump() {
        let dump = (0..<37).map { "place\($0)" }
        let spec = QuerySpec(clauses: [QueryClause([.place(dump), .content(["landscape"])])])
        let out = QuerySpecSanitizer.sanitize(spec)
        #expect(out.clauses[0].conditions == [.content(["landscape"])])
    }

    @Test("include と exclude の衝突は除外が勝つ（v2 実障害: people が両方に入り全滅）")
    func excludeWinsConflict() {
        let spec = QuerySpec(clauses: [QueryClause([
            .content(["people"]),
            .not(.content(["people"])),
        ])])
        let out = QuerySpecSanitizer.sanitize(spec)
        #expect(out.clauses[0].conditions == [.not(.content(["people"]))])
    }

    @Test("全条件が消えた節は捨てる（clauses 空＝純意味検索へ）")
    func emptyClauseRemoved() {
        let spec = QuerySpec(clauses: [QueryClause([.place(["any"]), .people(["none"])])])
        let out = QuerySpecSanitizer.sanitize(spec)
        #expect(out.clauses.isEmpty)
    }

    @Test("正常な条件はそのまま通す")
    func passesValidThrough() {
        let spec = QuerySpec(clauses: [QueryClause([
            .place(["沖縄県"]),
            .content(["beach"]),
            .not(.content(["people"])),
            .favorite,
        ])])
        let out = QuerySpecSanitizer.sanitize(spec)
        #expect(out == spec)
    }

    // MARK: - P0: 接地サニタイズ（決定的日付・place/people の接地）

    private let now = Date()

    @Test("日付は RelativeDateParser が唯一の出典（LLM の date は捨てて置換）")
    func deterministicDateWins() {
        // LLM が「ここ2年」を year 2026 と誤解釈した実障害の再現。
        let llmSpec = QuerySpec(clauses: [QueryClause([
            .date(.year(2026)),                 // ← LLM の誤り
            .content(["child"]),
        ])])
        let out = QuerySpecSanitizer.sanitize(llmSpec, criteria: "ここ2年以内の子供の写真", now: now)
        #expect(out.clauses.count == 1)
        #expect(out.clauses[0].conditions.contains(.date(.lastYears(2))))     // パーサの結果
        #expect(!out.clauses[0].conditions.contains(.date(.year(2026))))      // LLM の日付は消える
        #expect(out.clauses[0].conditions.contains(.content(["child"])))
    }

    @Test("LLM の節が全滅しても決定的日付だけの節が立つ")
    func dateOnlyClauseSurvives() {
        let llmSpec = QuerySpec(clauses: [QueryClause([.place(["any"])])])   // サニタイズで全滅
        let out = QuerySpecSanitizer.sanitize(llmSpec, criteria: "ここ2年の写真", now: now)
        #expect(out.clauses == [QueryClause([.date(.lastYears(2))])])
    }

    @Test("原文に日付表現が無ければ LLM の date は消えるだけ（勝手に付与しない）")
    func noDateWhenParserSilent() {
        let llmSpec = QuerySpec(clauses: [QueryClause([.date(.year(2026)), .content(["beach"])])])
        let out = QuerySpecSanitizer.sanitize(llmSpec, criteria: "ビーチの写真", now: now)
        #expect(out.clauses == [QueryClause([.content(["beach"])])])
    }

    @Test("place/people はカタログ一致 or 原文出現のみ残す（幻覚語は消える）")
    func groundingFiltersHallucinations() {
        let llmSpec = QuerySpec(clauses: [QueryClause([
            .place(["children", "沖縄県"]),     // "children" は幻覚（実障害）・沖縄県はカタログにある
            .people(["children"]),              // 幻覚
            .content(["child"]),
        ])])
        let out = QuerySpecSanitizer.sanitize(llmSpec, criteria: "沖縄の子供の写真", now: now,
                                              placeCatalog: ["沖縄県", "港区"], peopleCatalog: ["Joe"])
        #expect(out.clauses[0].conditions.contains(.place(["沖縄県"])))
        #expect(!out.clauses[0].conditions.contains { if case .people = $0 { return true } else { return false } })
    }

    @Test("カタログに無くても原文にそのまま出現する語は残す（存在しない地名の許容）")
    func criteriaTypedTermSurvives() {
        let llmSpec = QuerySpec(clauses: [QueryClause([.place(["モルディブ"])])])
        let out = QuerySpecSanitizer.sanitize(llmSpec, criteria: "モルディブの写真", now: now,
                                              placeCatalog: ["港区"])
        #expect(out.clauses[0].conditions.contains(.place(["モルディブ"])))
    }

    @Test("looksUntranslated: 日本語のままは true・英語は false")
    func untranslatedDetection() {
        #expect(AIAlbumService.looksUntranslated("ここ2年以内の子供の写真"))
        #expect(!AIAlbumService.looksUntranslated("Photos of children from the last 2 years"))
        #expect(AIAlbumService.looksUntranslated(""))
        #expect(!AIAlbumService.looksUntranslated("Child"))
    }

    @Test("positivePhrase: include 優先・無ければ否定節を落とした英訳文")
    func positivePhraseRules() {
        #expect(AIAlbumSearcher.positivePhrase(include: ["landscape"], semanticText: "whatever") == "landscape")
        #expect(AIAlbumSearcher.positivePhrase(
            include: [], semanticText: "A landscape photo without any people.") == "A landscape photo")
        #expect(AIAlbumSearcher.positivePhrase(
            include: [], semanticText: "Beach photos with no crowds") == "Beach photos")
        #expect(AIAlbumSearcher.positivePhrase(
            include: [], semanticText: "Sunset photos") == "Sunset photos")   // マーカー無し＝そのまま
    }
}
