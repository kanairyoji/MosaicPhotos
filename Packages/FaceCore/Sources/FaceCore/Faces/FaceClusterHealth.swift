import Foundation

/// **クラスタの健全さ（ばらつき）を 1 つの数にする**（純ロジック・テスト対象・ADR-210）。
///
/// ## 何を測るか
/// メンバーが重心からどれだけ散らばっているか＝`distance = 1 − cos` の**品質重み付き中央値**。
///
/// ⚠️ **平均ではなく中央値**。平均は 1〜2 枚の外れ顔で跳ね上がるので、
/// 「たまたま横顔が 1 枚入っている健全な人物」と「半分が別人のクラスタ」が同じ値になる。
/// 中央値なら「過半がどれだけ散っているか」＝混入の有無そのものを見ることになる。
/// 重みを品質にするのは、ぼけ顔が散らばりの判断まで支配しないため（重心の作り方と同じ規則）。
///
/// ## 何に使うか（2 つ）
/// 1. **事後監査の順番**（ADR-69）。「この人物、実は 2 人では？」を尋ねる相手を、
///    大きい順ではなく**散らばっている順**に選ぶ。2-means より桁で安い足切りになる。
/// 2. **判定の内訳**（ADR-135）に出す。「なぜこの人物がおかしいのか」を数で言えるようにする。
///
/// ⚠️ 以前は「散らばりが `1 − しきい値` を超えた人物の重心を凍結する」にも使っていたが、
/// FG-NET / LFW で一度も発動せず（散らばりの最大 0.47 に対してバー 0.65）、バーを下げても
/// 効かなかったため撤回した（ADR-216）。
public enum FaceClusterHealth {

    /// ばらつきを判断してよい最小メンバー数。
    ///
    /// ⚠️ 少数のクラスタでは中央値が 1 枚で決まる（2 枚なら小さい方そのもの）。
    /// 断片を「散らばっている」と言っても意味がない。
    /// 事後監査の最小メンバー数（`FaceClusterAudit.Config.minMembers`）と同じ 8 に合わせる。
    public static let minMembersToJudge = 8

    /// 品質重み付き中央値の散らばり。メンバーが空なら nil（「測っていない」と「0」を区別する）。
    ///
    /// - Parameters:
    ///   - members: (正規化前でよい埋め込み, 品質)。
    ///   - centroid: クラスタの重心（正規化前でよい）。
    public static func spread(members: [(embedding: [Float], quality: Float)],
                             centroid: [Float]) -> Float? {
        guard !members.isEmpty else { return nil }
        let c = FaceClustering.normalized(centroid)
        var samples: [(distance: Float, weight: Float)] = []
        samples.reserveCapacity(members.count)
        for member in members {
            let v = FaceClustering.normalized(member.embedding)
            guard v.count == c.count else { continue }
            samples.append((1 - FaceClustering.dot(v, c), max(member.quality, 0.01)))
        }
        return weightedMedian(samples)
    }

    /// 重み付き中央値（重みの累積が半分に達する最初の値）。
    ///
    /// ⚠️ 同値で並んだときは**値で安定ソート済み**なので結果は決定的。
    /// 境界のカウントが実行ごとに揺れる（`face-accuracy.md` のハーネス再現性）のと
    /// 同じ罠を踏まないよう、ここでは辞書・集合の反復順序に一切依存しない。
    public static func weightedMedian(_ samples: [(distance: Float, weight: Float)]) -> Float? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted { $0.distance < $1.distance }
        let total = sorted.reduce(Float(0)) { $0 + $1.weight }
        guard total > 0 else { return sorted[sorted.count / 2].distance }
        var seen: Float = 0
        for sample in sorted {
            seen += sample.weight
            if seen * 2 >= total { return sample.distance }
        }
        return sorted[sorted.count - 1].distance
    }

    /// 監査で尋ねる順番（散らばっている順 → 同値はクラスタ ID の小さい順で決定的に）。
    public static func auditOrder<T>(_ items: [T], spread: (T) -> Float?,
                                     clusterID: (T) -> Int) -> [T] {
        items.sorted { a, b in
            let sa = spread(a) ?? -1, sb = spread(b) ?? -1
            if sa != sb { return sa > sb }
            return clusterID(a) < clusterID(b)
        }
    }
}
