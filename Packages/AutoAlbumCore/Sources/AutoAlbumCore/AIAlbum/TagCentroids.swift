import Foundation
import MosaicSupport
import PerceptionCore

/// タグごとの **CLIP 画像埋め込みの重心**を作る（ADR-101）。
///
/// 「`風景` は `mountain` という**語**に近いか」ではなく「`mountain` タグが付いた**写真たち**に
/// 近いか」を問えるようにするための材料。CLIP は画像↔説明文の一致だけを学習しているので、
/// 語同士の比較（実測 F1 0.300）より重心との比較（同 0.761）の方が正しく効く。
///
/// コスト: 画像埋め込みは全写真ぶん既にある（`PhotoEmbedding`・Float16）ので**新規の推論はゼロ**。
/// ページ走査して足し込むだけ。呼び手（`CLIPConceptExpander`）がキャッシュする。
public enum TagCentroids {

    /// 重心を採用する最小枚数。少数枚の平均は 1 枚の写真とほぼ変わらず、タグの意味を代表しない
    /// （誤タグ 1 枚で重心が飛ぶ）。この閾値を満たさないタグは語彙から実質的に外れる。
    public static let minPhotosPerTag = 20

    /// 1 ページの件数（メモリを有界にする。検索の意味採点と同じ考え方）。
    public static let pageSize = 2_000

    /// - Parameters:
    ///   - vocabulary: 重心を作りたいタグ（`TagStore.tagVocabulary`）。
    ///   - tagsByRefKey: refKey → その写真のタグ（`TagStore.allTags`）。
    ///   - loadPage: 埋め込みのページ供給（`AutoAlbumStore.enrichmentVectorPage`）。
    /// - Returns: タグ → L2 正規化した重心（枚数不足のタグは含めない）。
    public static func build(vocabulary: [String],
                             tagsByRefKey: [String: [String]],
                             loadPage: (_ offset: Int, _ limit: Int) async -> [(refKey: String, clipVector: Data)]
    ) async -> [String: [Float]] {
        guard !vocabulary.isEmpty, !tagsByRefKey.isEmpty else { return [:] }
        let wanted = Set(vocabulary.map { $0.lowercased() })
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]

        var offset = 0
        while true {
            if Task.isCancelled { return [:] }
            let page = await loadPage(offset, pageSize)
            if page.isEmpty { break }
            for entry in page {
                guard let tags = tagsByRefKey[entry.refKey], !tags.isEmpty,
                      let vector = ClipMath.decode(entry.clipVector), !vector.isEmpty else { continue }
                for raw in tags {
                    let tag = raw.lowercased()
                    guard wanted.contains(tag) else { continue }
                    if var sum = sums[tag] {
                        // 次元が食い違う（モデル差し替え途中など）ものは混ぜない。
                        guard sum.count == vector.count else { continue }
                        for i in 0..<sum.count { sum[i] += vector[i] }
                        sums[tag] = sum
                    } else {
                        sums[tag] = vector
                    }
                    counts[tag, default: 0] += 1
                }
            }
            offset += page.count
            if page.count < pageSize { break }
        }

        var out: [String: [Float]] = [:]
        for (tag, sum) in sums where (counts[tag] ?? 0) >= minPhotosPerTag {
            var v = sum
            var norm: Float = 0
            for x in v { norm += x * x }
            norm = norm.squareRoot()
            guard norm > 0 else { continue }
            for i in 0..<v.count { v[i] /= norm }
            out[tag] = v
        }
        Diagnostics.mark("aialbum.centroids: \(out.count)/\(vocabulary.count) tags "
                         + "(min \(minPhotosPerTag) photos, scanned \(offset))")
        return out
    }
}
