import Foundation
@testable import AutoAlbumCore

/// 評価フィクスチャ（centroids.json の相互類似行列）から凝集コンテキストを作る共通ヘルパ。
enum CoherenceFixtureSupport {
    /// フィクスチャの相互類似行列から凝集コンテキスト（集合 z＋限界 z）を作る
    /// （本番 `CLIPConceptExpander.coherenceContext` と同じ規則・S12）。
    static func coherenceContext(_ m: [[Double]]?) -> CoherenceContext? {
        guard let m, !m.isEmpty else { return nil }
        var background: [Double] = []
        for a in 0..<m.count { for b in (a + 1)..<m.count { background.append(m[a][b]) } }
        let mean = background.reduce(0, +) / Double(background.count)
        let sd = (background.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(background.count)).squareRoot()
        guard sd > 0 else { return nil }
        return CoherenceContext(
            setZ: { indices in
                guard indices.count >= 2 else { return 0 }
                var total = 0.0; var count = 0
                for i in 0..<indices.count {
                    for j in (i + 1)..<indices.count { total += m[indices[i]][indices[j]]; count += 1 }
                }
                return (total / Double(count) - mean) / sd
            },
            marginalZ: { candidate, group in
                guard !group.isEmpty else { return 0 }
                let total = group.reduce(0.0) { $0 + m[candidate][$1] }
                return (total / Double(group.count) - mean) / sd
            })
    }
}
