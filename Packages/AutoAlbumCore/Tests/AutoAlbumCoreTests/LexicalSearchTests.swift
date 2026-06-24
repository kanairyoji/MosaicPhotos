import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("LexicalSearch / HybridFusion")
struct LexicalSearchTests {

    private func photo(_ id: String, place: String? = nil, country: String? = nil,
                       people: [String] = []) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: nil, latitude: nil, longitude: nil,
                      placeName: place, country: country, people: people)
    }

    @Test("地名・国・人物に部分一致でヒットし、マッチ数の多い順")
    func ranksByMatchCount() {
        let photos = [
            photo("a", place: "Kyoto Station"),
            photo("b", place: "random place"),
            photo("c", place: "Kyoto", country: "Kyoto-fu"),   // 2フィールドで一致
        ]
        let result = LexicalSearch.rank(photos, keywords: ["kyoto"])
        #expect(result.map { PhotoRef.decode($0.id)?.localIdentifier } == ["c", "a"])
    }

    @Test("一致が無ければ空")
    func emptyWhenNoMatch() {
        let photos = [photo("a", place: "Osaka"), photo("b", place: "Tokyo")]
        #expect(LexicalSearch.rank(photos, keywords: ["mountain"]).isEmpty)
    }

    @Test("RRF：両方の検索に出る写真が上位に来る")
    func fusionRanksSharedHigher() {
        let a = photo("a"), b = photo("b"), c = photo("c")
        let lexical = [a, b]      // a が字句1位
        let semantic = [b, c]     // b が意味1位、両方に出る
        let fused = HybridFusion.fuse([lexical, semantic])
        #expect(fused.first.map { PhotoRef.decode($0.id)?.localIdentifier } == "b")   // 両リスト出現で最上位
        #expect(Set(fused.map { PhotoRef.decode($0.id)?.localIdentifier }) == ["a", "b", "c"])
    }

    @Test("空リストは無視する")
    func fusionIgnoresEmpty() {
        let only = [photo("x"), photo("y")]
        let fused = HybridFusion.fuse([[], only, []])
        #expect(fused.map { PhotoRef.decode($0.id)?.localIdentifier } == ["x", "y"])
    }
}
