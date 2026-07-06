import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("AIAlbumSearcher (search / buildInfo)")
struct AIAlbumSearchTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func photo(_ id: String, place: String, clip: [Float]? = nil) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: now, latitude: nil, longitude: nil,
                      placeName: place, clipVector: clip.map { ClipMath.encode($0) })
    }

    /// 固定ベクトルを返す CLIP テキスト埋め込みのスタブ。
    private struct StubEmbedder: TextEmbedder {
        let vector: [Float]?
        var isAvailable: Bool { vector != nil }
        func embed(_ text: String) async -> [Float]? { vector }
    }

    // 旧 flat API（AIAlbumQuery 直接検索）は撤去済み。以下は spec 経路での等価テスト。

    @Test("semanticText が指定されれば、include 語ではなくそれを CLIP に埋め込む")
    func usesSemanticTextForEmbedding() async {
        final class RecordingEmbedder: TextEmbedder, @unchecked Sendable {
            var lastText: String?
            var isAvailable: Bool { true }
            func embed(_ text: String) async -> [Float]? { lastText = text; return [1, 0] }
        }
        let embedder = RecordingEmbedder()
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("near", place: "Tokyo", clip: [1, 0])]
        let spec = QuerySpec(clauses: [QueryClause([.place(["tokyo"]), .content(["dog"])])])
        _ = await searcher.search(baseLite: photos, spec: spec, now: now,
                                  semanticText: "a running child", loadPage: pagedLoader(photos))
        #expect(embedder.lastText == "a running child")   // include("dog") ではなく英訳文を使う
    }

    @Test("内容の意図があるのに当たらなければ空（タグなし写真の混入・全件化を防ぐ）")
    func contentIntentNoMatchReturnsEmpty() async {
        // 直交ベクトル＝意味 0 件・タグ無し・字句無し → 空（base へフォールバックしない）。
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [0, 1]))
        let photos = [photo("a", place: "Tokyo", clip: [1, 0]), photo("b", place: "Osaka", clip: [1, 0])]
        let spec = QuerySpec(clauses: [QueryClause([.content(["unrelated"])])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now,
                                           semanticText: "something unrelated",
                                           loadPage: pagedLoader(photos))
        #expect(result.isEmpty)
    }

    @Test("buildInfo はタイトル補完・criteria 保持・件数を組み立てる")
    func buildsInfo() {
        let members = [photo("a", place: "Okinawa"), photo("b", place: "Okinawa")]
        let info = AIAlbumSearcher.buildInfo(id: "aiAlbum:x", title: "", interpretedTitle: "沖縄の思い出",
                                             criteria: "ここ数年の沖縄", members: members)
        #expect(info.title == "沖縄の思い出")   // タイトル空→解釈タイトルで補完
        #expect(info.criteria == "ここ数年の沖縄")
        #expect(info.photoCount == 2)
        #expect(info.strategyID == AIAlbumStrategy.strategyID)
    }

    @Test("buildInfo はユーザー指定タイトルを優先する")
    func buildsInfoUserTitle() {
        let info = AIAlbumSearcher.buildInfo(id: "aiAlbum:y", title: "旅の記録", interpretedTitle: "",
                                             criteria: "ここ数年の沖縄", members: [photo("a", place: "X")])
        #expect(info.title == "旅の記録")
    }

    // MARK: - QuerySpec 版（OR / ハード＋内容）

    private func pagedLoader(_ photos: [EnrichedPhoto]) -> (Int, Int) async -> [(refKey: String, clipVector: Data)] {
        let embedded = photos.compactMap { ph in ph.clipVector.map { (ph.id, $0) } }.sorted { $0.0 < $1.0 }
        return { offset, limit in embedded.dropFirst(offset).prefix(limit).map { (refKey: $0.0, clipVector: $0.1) } }
    }

    @Test("QuerySpec: OR（京都 or 大阪）のハード絞り込み（内容語なし）")
    func specOrHardOnly() async {
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let photos = [photo("kyoto", place: "Kyoto", clip: [1, 0]),
                      photo("osaka", place: "Osaka", clip: [1, 0]),
                      photo("nagoya", place: "Nagoya", clip: [1, 0])]
        let spec = QuerySpec(clauses: [QueryClause([.place(["kyoto"])]), QueryClause([.place(["osaka"])])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now, semanticText: "",
                                           loadPage: pagedLoader(photos))
        #expect(Set(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier }) == ["kyoto", "osaka"])
    }

    @Test("安全網: ハードで全滅でも内容の意図があれば内容のみへ緩和して空にしない")
    func specRelaxesWhenHardEmpties() async {
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [1, 0]))
        let photos = [photo("a", place: "Tokyo", clip: [1, 0]), photo("b", place: "Osaka", clip: [1, 0])]
        // place "mars" はどの写真にも該当しない（ハード全滅）→ 内容(beach)で緩和して採点。
        let spec = QuerySpec(clauses: [QueryClause([.place(["mars"]), .content(["beach"])])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now, semanticText: "beach",
                                           loadPage: pagedLoader(photos))
        #expect(!result.isEmpty)   // 緩和により内容マッチが返る（「何も出ない」を防ぐ）
    }

    @Test("QuerySpec: ハード（場所）＋内容（CLIP）で意味的に絞る")
    func specHardPlusContent() async {
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [1, 0]))
        let photos = [photo("near", place: "Tokyo", clip: [1, 0]),
                      photo("far", place: "Tokyo", clip: [-1, 0]),      // 閾値未満
                      photo("osaka", place: "Osaka", clip: [1, 0])]     // 場所で除外
        let spec = QuerySpec(clauses: [QueryClause([.place(["tokyo"]), .content(["beach"])])])
        let result = await searcher.search(baseLite: photos, spec: spec, now: now, semanticText: "beach",
                                           loadPage: pagedLoader(photos))
        #expect(result.compactMap { PhotoRef.decode($0.id)?.localIdentifier } == ["near"])
    }
}
