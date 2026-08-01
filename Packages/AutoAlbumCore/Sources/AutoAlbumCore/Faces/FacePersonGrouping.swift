import Foundation

/// 2 階層の人物モデル（**人物 = 複数の顔クラスタの束**・純ロジック・テスト対象）。
///
/// 成長期の子供は乳児期・幼児期・児童期で顔の埋め込みが本質的に離れる（別人の同年代より
/// 遠いことすらある）。無理に 1 クラスタへ**融合**すると重心が中間に壊れ、以後どちらの新規顔も
/// 中途半端な類似度になる。そこでクラスタは**純度の高いまま別々に保持**し、上位の「人物（Person）」で
/// 束ねる。帰属は「その人物のどれかのクラスタに近ければ本人」＝クラスタ横断の**最大類似度**で判定する。
/// 束ねる操作はユーザー（確実・一度きり）が行う想定で、クラスタリング自体は一切変えない。
public enum FacePersonGrouping {

    /// 1 人物のモデル。複数クラスタの代表ベクトル（各クラスタの重心＋確認アンカー等）を持つ。
    public struct PersonModel: Sendable, Equatable {
        public let personID: Int
        /// この人物に束ねられた各クラスタの代表ベクトル群（正規化済み）。
        public let clusterReps: [[Float]]

        public init(personID: Int, clusterReps: [[Float]]) {
            self.personID = personID
            self.clusterReps = clusterReps
        }
    }

    /// 新規顔を最も近い人物へ帰属する。人物との類似度＝その人物の**全クラスタ代表との最大**。
    /// `threshold` 未満なら nil（未知の人物）。融合方式（人物 = 1 重心）との対比用に、
    /// clusterReps が 1 本なら従来の単一重心判定に一致する。
    public static func nearestPerson(_ embedding: [Float], persons: [PersonModel],
                                     threshold: Float = 0) -> (personID: Int, similarity: Float)? {
        let v = FaceClustering.normalized(embedding)
        var best: (id: Int, sim: Float)?
        for p in persons {
            var sim: Float = -2
            for rep in p.clusterReps { sim = max(sim, FaceClustering.dot(v, rep)) }
            if best == nil || sim > best!.sim { best = (p.personID, sim) }
        }
        guard let b = best, b.sim >= threshold else { return nil }
        return (b.id, b.sim)
    }

    /// 融合方式の人物代表（束ねたクラスタ群を 1 つの重心に潰す）。2 階層との対比計測用。
    /// 全代表を単純平均→正規化（クラスタサイズの重みは持たない＝評価上の単純比較）。
    public static func fusedRep(_ clusterReps: [[Float]]) -> [Float]? {
        guard let first = clusterReps.first, !first.isEmpty,
              clusterReps.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for rep in clusterReps {
            let n = FaceClustering.normalized(rep)
            for i in sum.indices { sum[i] += n[i] }
        }
        return FaceClustering.normalized(sum)
    }
}
