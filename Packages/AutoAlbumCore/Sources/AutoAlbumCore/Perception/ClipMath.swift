import Foundation

/// CLIP 埋め込みベクトルの保存・比較の純ロジック（Foundation のみ・テスト対象）。
/// ベクトルは `[Float]`。永続化は FP32 little-endian の `Data`。検索はコサイン類似。
public enum ClipMath {

    /// `[Float]` → `Data`（FP32 LE）。SwiftData の `clipVector: Data?` に保存する。
    public static func encode(_ vector: [Float]) -> Data {
        var le = vector.map { $0.bitPattern.littleEndian }
        return Data(bytes: &le, count: le.count * MemoryLayout<UInt32>.size)
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
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }
}

/// クエリのテキスト埋め込みに対し、写真を意味的に並べ替える純ロジック（テスト対象）。
/// `clipVector` を持つ写真のみ対象。閾値以上・上位 K を返す。
public enum SemanticRanker {

    public struct Scored: Sendable, Equatable {
        public let photo: EnrichedPhoto
        public let score: Float
    }

    /// `queryVector`（テキスト埋め込み）に近い順に写真を返す。
    public static func rank(_ photos: [EnrichedPhoto], queryVector: [Float],
                            topK: Int = 60, threshold: Float = 0.2) -> [Scored] {
        guard !queryVector.isEmpty else { return [] }
        var scored: [Scored] = []
        for photo in photos {
            guard let data = photo.clipVector, let vec = ClipMath.decode(data) else { continue }
            let score = ClipMath.cosine(queryVector, vec)
            if score >= threshold { scored.append(Scored(photo: photo, score: score)) }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(topK))
    }
}
