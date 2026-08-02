import Accelerate
import Foundation

/// CLIP 埋め込みベクトルの保存・比較の純ロジック（Foundation のみ・テスト対象）。
/// ベクトルは `[Float]`。永続化は FP32 little-endian の `Data`。検索はコサイン類似。
public enum ClipMath {

    /// `[Float]` → `Data`（FP32 LE）。SwiftData の `clipVector: Data?` に保存する。
    public static func encode(_ vector: [Float]) -> Data {
        var le = vector.map { $0.bitPattern.littleEndian }
        return Data(bytes: &le, count: le.count * MemoryLayout<UInt32>.size)
    }

    /// `[Float]` → `Data`（Float16 LE）。埋め込みの永続化はこの半精度を使い、DB と
    /// ページ常駐量を約半分にする（CLIP コサインは fp16 でも実用上の精度を保つ）。
    public static func encodeHalf(_ vector: [Float]) -> Data {
        var le = vector.map { Float16($0).bitPattern.littleEndian }
        return Data(bytes: &le, count: le.count * MemoryLayout<UInt16>.size)
    }

    /// Float16 LE `Data` → `[Float]`（fp32 へ復元）。壊れた長さは nil。
    public static func decodeHalf(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<UInt16>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<UInt16>.size
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = data[data.startIndex + i * 2]
            let hi = data[data.startIndex + i * 2 + 1]
            let bits = UInt16(lo) | (UInt16(hi) << 8)
            result[i] = Float(Float16(bitPattern: UInt16(littleEndian: bits)))
        }
        return result
    }

    /// `Data` → `[Float]`。壊れた長さは nil。
    public static func decode(_ data: Data) -> [Float]? {
        guard data.count % MemoryLayout<UInt32>.size == 0 else { return nil }
        let count = data.count / MemoryLayout<UInt32>.size
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = data[data.startIndex + i * 4]
            let b1 = data[data.startIndex + i * 4 + 1]
            let b2 = data[data.startIndex + i * 4 + 2]
            let hi = data[data.startIndex + i * 4 + 3]
            let bits = UInt32(lo) | (UInt32(b1) << 8) | (UInt32(b2) << 16) | (UInt32(hi) << 24)
            result[i] = Float(bitPattern: UInt32(littleEndian: bits))
        }
        return result
    }

    /// コサイン類似（-1…1）。次元不一致・ゼロベクトルは 0。
    /// B1: vDSP（SIMD）で計算する。意味検索は数万件×512 次元をこの関数で採点するため、
    /// スカラーループだと AI アルバム作成（ユーザーが待つ）の本体コストになっていた（~5-10 倍差）。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = (na * nb).squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}
