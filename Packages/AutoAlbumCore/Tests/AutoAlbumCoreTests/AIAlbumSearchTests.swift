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

    @Test("CLIP があれば内容語で意味的に並べ替える")
    func clipSemanticRank() async {
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [1, 0]))
        let photos = [photo("near", place: "Tokyo", clip: [1, 0]),
                      photo("far", place: "Tokyo", clip: [-1, 0])]   // 閾値未満で除外
        var q = AIAlbumQuery()
        q.placeTerms = ["tokyo"]
        q.keywords = ["beach"]
        let result = await searcher.search(photos, query: q, now: now)
        #expect(result.map { PhotoRef.decode($0.id)?.localIdentifier } == ["near"])
    }

    @Test("バッチ版 search は純関数版と完全一致（メモリ削減で認識率は不変）")
    func batchedEqualsPure() async {
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [1, 0, 0]))
        // distinct なコサインになる様々な角度。一部はフロア未満、1枚は clipVector なし。
        let withClip = [
            photo("a", place: "Tokyo", clip: [1.0, 0.0, 0.0]),
            photo("b", place: "Tokyo", clip: [0.9, 0.1, 0.0]),
            photo("c", place: "Tokyo", clip: [0.7, 0.7, 0.0]),
            photo("d", place: "Tokyo", clip: [0.3, 0.95, 0.0]),
            photo("e", place: "Tokyo", clip: [-1.0, 0.0, 0.0]),
            photo("f", place: "Tokyo"),   // clipVector なし → 両方で除外
        ]
        var q = AIAlbumQuery()
        q.placeTerms = ["tokyo"]
        q.keywords = ["beach"]

        // 純関数版（全件 clipVector 込み）。
        let pure = await searcher.search(withClip, query: q, now: now, semanticText: "beach")

        // バッチ版：lite メタ（clipVector なし）＋ refKey 昇順のページ取得（pageSize=2 で複数ページ）。
        let lite = withClip.map {
            EnrichedPhoto(id: $0.id, captureDate: $0.captureDate, latitude: $0.latitude,
                          longitude: $0.longitude, placeName: $0.placeName, clipVector: nil)
        }
        let embedded = withClip
            .compactMap { ph in ph.clipVector.map { (ph.id, $0) } }
            .sorted { $0.0 < $1.0 }
        let batched = await searcher.search(
            baseLite: lite, query: q, now: now, semanticText: "beach", pageSize: 2,
            loadPage: { offset, limit in
                embedded.dropFirst(offset).prefix(limit).map { (refKey: $0.0, clipVector: $0.1) }
            })

        #expect(!pure.isEmpty)
        #expect(pure.map(\.id) == batched.map(\.id))   // メンバー・順位ともに一致
    }

    @Test("semanticText が指定されれば、keywords ではなくそれを CLIP に埋め込む")
    func usesSemanticTextForEmbedding() async {
        final class RecordingEmbedder: TextEmbedder, @unchecked Sendable {
            var lastText: String?
            var isAvailable: Bool { true }
            func embed(_ text: String) async -> [Float]? { lastText = text; return [1, 0] }
        }
        let embedder = RecordingEmbedder()
        let searcher = AIAlbumSearcher(textEmbedder: embedder)
        let photos = [photo("near", place: "Tokyo", clip: [1, 0])]
        var q = AIAlbumQuery()
        q.placeTerms = ["tokyo"]
        q.keywords = ["dog"]
        _ = await searcher.search(photos, query: q, now: now, semanticText: "a running child")
        #expect(embedder.lastText == "a running child")   // keywords("dog") ではなく英訳文を使う
    }

    @Test("CLIP が使えなければ内容語は無視して構造化結果を返す（no-match にしない）")
    func noClipFallsBackToBase() async {
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let photos = [photo("a", place: "Tokyo"), photo("b", place: "Tokyo")]
        var q = AIAlbumQuery()
        q.placeTerms = ["tokyo"]
        q.keywords = ["mountain"]
        let result = await searcher.search(photos, query: q, now: now)
        #expect(result.count == 2)
    }

    @Test("内容語だけで当たらなければ全件ではなく空を返す（タグなし写真の混入を防ぐ）")
    func contentOnlyNoMatchReturnsEmpty() async {
        // 直交ベクトルで意味検索は閾値未満＝0件。構造化条件なし。
        let searcher = AIAlbumSearcher(textEmbedder: StubEmbedder(vector: [0, 1]))
        let photos = [photo("a", place: "Tokyo", clip: [1, 0]), photo("b", place: "Osaka", clip: [1, 0])]
        let result = await searcher.search(photos, query: AIAlbumQuery(), now: now,
                                           semanticText: "something unrelated")
        #expect(result.isEmpty)   // 全件フォールバックしない
    }

    @Test("ハード条件が空なら空（base が空のときは内容語を見ない）")
    func emptyBase() async {
        let searcher = AIAlbumSearcher(textEmbedder: nil)
        let photos = [photo("a", place: "Tokyo")]
        var q = AIAlbumQuery()
        q.placeTerms = ["osaka"]   // 一致なし
        let result = await searcher.search(photos, query: q, now: now)
        #expect(result.isEmpty)
    }

    @Test("buildInfo はタイトル補完・criteria 保持・件数を組み立てる")
    func buildsInfo() {
        let members = [photo("a", place: "Okinawa"), photo("b", place: "Okinawa")]
        var query = AIAlbumQuery()
        query.title = "沖縄の思い出"
        let info = AIAlbumSearcher.buildInfo(id: "aiAlbum:x", title: "", query: query,
                                             criteria: "ここ数年の沖縄", members: members)
        #expect(info.title == "沖縄の思い出")   // タイトル空→解釈タイトルで補完
        #expect(info.criteria == "ここ数年の沖縄")
        #expect(info.photoCount == 2)
        #expect(info.strategyID == AIAlbumStrategy.strategyID)
    }

    @Test("buildInfo はユーザー指定タイトルを優先する")
    func buildsInfoUserTitle() {
        let info = AIAlbumSearcher.buildInfo(id: "aiAlbum:y", title: "旅の記録", query: AIAlbumQuery(),
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
