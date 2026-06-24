import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("ClipMath / SemanticRanker / scene tags")
struct ClipMathTests {

    @Test("encode/decode が往復する")
    func roundTrips() {
        let v: [Float] = [0.5, -1.25, 3.0, 0.0, 12345.6]
        let decoded = ClipMath.decode(ClipMath.encode(v))
        #expect(decoded == v)
    }

    @Test("コサイン類似：同方向=1、直交=0、逆=-1")
    func cosineBasics() {
        #expect(abs(ClipMath.cosine([1, 0], [2, 0]) - 1) < 1e-6)
        #expect(abs(ClipMath.cosine([1, 0], [0, 1])) < 1e-6)
        #expect(abs(ClipMath.cosine([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    @Test("次元不一致・空・ゼロは 0")
    func cosineEdgeCases() {
        #expect(ClipMath.cosine([1, 2], [1, 2, 3]) == 0)
        #expect(ClipMath.cosine([], []) == 0)
        #expect(ClipMath.cosine([0, 0], [1, 1]) == 0)
    }

    @Test("SemanticRanker は近い順・閾値・topK で返す")
    func ranks() {
        func photo(_ id: String, _ vec: [Float]) -> EnrichedPhoto {
            EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: nil, latitude: nil, longitude: nil,
                          placeName: nil, clipVector: ClipMath.encode(vec))
        }
        let photos = [
            photo("near", [1, 0]),
            photo("mid", [0.7, 0.7]),
            photo("far", [-1, 0]),                           // 閾値未満で除外
            EnrichedPhoto(id: PhotoRef.local("none").encoded, captureDate: nil, latitude: nil,
                          longitude: nil, placeName: nil),    // ベクトル無し→除外
        ]
        let ranked = SemanticRanker.rank(photos, queryVector: [1, 0], topK: 10, threshold: 0.2)
        #expect(ranked.map { PhotoRef.decode($0.photo.id)?.localIdentifier } == ["near", "mid"])
        #expect(ranked[0].score > ranked[1].score)
    }

}
