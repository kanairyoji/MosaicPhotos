import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("ClipMath")
struct ClipMathTests {

    @Test("encode/decode が往復する")
    func roundTrips() {
        let v: [Float] = [0.5, -1.25, 3.0, 0.0, 12345.6]
        let decoded = ClipMath.decode(ClipMath.encode(v))
        #expect(decoded == v)
    }

    @Test("Float16 encode/decode は近似往復（半精度・サイズ半分）")
    func halfRoundTrips() {
        let v: [Float] = [0.5, -1.25, 3.0, 0.0, 0.123]
        let data = ClipMath.encodeHalf(v)
        // 半精度は1要素2バイト（fp32 の半分）。
        #expect(data.count == v.count * 2)
        let decoded = ClipMath.decodeHalf(data)!
        #expect(decoded.count == v.count)
        for (a, b) in zip(decoded, v) {
            #expect(abs(a - b) <= 0.01 + abs(b) * 0.001)   // fp16 の量子化誤差内
        }
    }

    @Test("Float16 でもコサイン類似は実用精度を保つ")
    func halfPreservesCosine() {
        let q: [Float] = (0..<64).map { Float(sin(Double($0))) }
        let p: [Float] = (0..<64).map { Float(sin(Double($0) + 0.05)) }
        let exact = ClipMath.cosine(q, p)
        let half = ClipMath.cosine(ClipMath.decodeHalf(ClipMath.encodeHalf(q))!,
                                   ClipMath.decodeHalf(ClipMath.encodeHalf(p))!)
        #expect(abs(exact - half) < 0.01)
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

}
