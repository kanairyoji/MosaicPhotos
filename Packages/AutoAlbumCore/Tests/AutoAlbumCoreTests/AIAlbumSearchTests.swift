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
}
