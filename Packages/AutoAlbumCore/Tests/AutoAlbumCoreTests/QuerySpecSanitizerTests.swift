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
