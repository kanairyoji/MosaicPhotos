import Foundation
import Testing
@testable import AutoAlbumCore

/// ハード接地語の内容語からの除外（ADR-109）。
/// 実障害:「バレエの太郎」で FM が content にも "太郎" を入れると、字句検索が人物名で
/// 太郎の全写真をヒットさせ、RRF 和集合経由で**バレエ証拠ゼロの写真**がメンバー入りした
/// （ハード AND のはずが実質 OR）。
@Suite("HardGroundedContent (人物×内容の AND)")
struct HardGroundedContentTests {

    private func photo(_ id: String, people: [String] = []) -> EnrichedPhoto {
        EnrichedPhoto(id: "L-\(id)", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                      latitude: nil, longitude: nil, placeName: nil, people: people)
    }

    // MARK: - effectiveContentTerms（純）

    @Test("人物条件に接地済みの語は内容語から除かれる（部分名も両方向で）")
    func stripsHardGroundedTerms() {
        let spec = QuerySpec(clauses: [QueryClause([
            .people(["山田太郎"]),
            .content(["ballet", "山田太郎"]),
        ])])
        #expect(spec.effectiveContentTerms.include == ["ballet"])

        // 「太郎」⊂「山田太郎」（FM が短縮名を吐くケース）も除く。
        let partial = QuerySpec(clauses: [QueryClause([
            .people(["山田太郎"]), .content(["ballet", "太郎"]),
        ])])
        #expect(partial.effectiveContentTerms.include == ["ballet"])

        // 場所も同じ（place で接地済みの地名を内容語に二重計上しない）。
        let place = QuerySpec(clauses: [QueryClause([
            .place(["横浜市"]), .content(["autumn leaves", "横浜市"]),
        ])])
        #expect(place.effectiveContentTerms.include == ["autumn leaves"])
    }

    @Test("ハード接地語が無ければ内容語は不変・除外語は対象外")
    func leavesContentWithoutHardTerms() {
        let spec = QuerySpec(clauses: [QueryClause([.content(["ballet", "stage"])])])
        #expect(spec.effectiveContentTerms.include == ["ballet", "stage"])

        let excl = QuerySpec(clauses: [QueryClause([
            .people(["山田太郎"]), .content(["ballet"]), .not(.content(["people"])),
        ])])
        #expect(excl.effectiveContentTerms.exclude == ["people"])
    }

    // MARK: - 検索の AND 動作（searchWithPool・CLIP なし＝タグ/字句で解く）

    /// 太郎の写真 4 枚（うち 2 枚に ballet タグ）＋他人のバレエ写真 1 枚。
    /// 「バレエの太郎」（people=太郎 AND content=[ballet, 太郎]）が返すのは
    /// **太郎∩バレエ = 2 枚だけ**であること。旧実装は字句チャネル（"太郎"→people 一致）が
    /// 太郎の全 4 枚を通していた。
    @Test("人物×内容は AND: 内容証拠の無い本人写真は入らない")
    func personAndContentIsConjunction() async {
        let taro = ["山田太郎"]
        let photos = [
            photo("t1", people: taro), photo("t2", people: taro),
            photo("t3", people: taro), photo("t4", people: taro),
            photo("other", people: ["鈴木花子"]),
        ]
        let tags = ["L-t1": ["ballet"], "L-t2": ["ballet", "stage"], "L-other": ["ballet"]]
        let spec = QuerySpec(clauses: [QueryClause([
            .people(taro), .content(["ballet", "山田太郎"]),
        ])])
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let (members, _) = await searcher.searchWithPool(
            baseLite: photos, spec: spec, now: Date(timeIntervalSince1970: 1_767_225_600),
            semanticText: "Ballet of Taro Yamada", photoTags: tags,
            loadPage: { _, _ in [] })
        #expect(Set(members.map(\.id)) == ["L-t1", "L-t2"],
                "太郎∩バレエ以外が混入/欠落: \(members.map(\.id))")
    }

    /// 内容語が全部ハード接地語（人物名だけ）のクエリは、ハード絞り込み結果＝本人の全写真を返す。
    /// 英訳文（"Photos of Taro"）で CLIP band すると本人の写真が恣意的に欠けるため。
    @Test("内容語が接地済み語のみなら、ハード通過分をそのまま返す")
    func hardGroundedOnlyContentReturnsBase() async {
        let taro = ["山田太郎"]
        let photos = [
            photo("t1", people: taro), photo("t2", people: taro), photo("t3", people: taro),
            photo("other", people: ["鈴木花子"]),
        ]
        let spec = QuerySpec(clauses: [QueryClause([
            .people(taro), .content(["山田太郎"]),
        ])])
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let (members, _) = await searcher.searchWithPool(
            baseLite: photos, spec: spec, now: Date(timeIntervalSince1970: 1_767_225_600),
            semanticText: "Photos of Taro Yamada", photoTags: [:],
            loadPage: { _, _ in [] })
        #expect(Set(members.map(\.id)) == ["L-t1", "L-t2", "L-t3"],
                "本人の全写真が返っていない: \(members.map(\.id))")
    }
}
