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

    /// 人物の顔を**撮影日で時期グループに分け**、各グループの重心を人物の代表にする（純・ADR-61）。
    /// 子供（`isChild`）は成長段階の代理として最大 `maxGroups` の時期グループ（子供は撮影日≒年齢）、
    /// **大人（isChild=false）は 1 つの融合グループ**（成人は見た目が一貫し分割が害になるため）。
    /// 撮影日 nil の顔は最古扱いに寄せる（欠損に強く）。帰属側は `nearestPerson`（最大類似度）。
    /// - Returns: 人物の代表ベクトル群（正規化済み）。子供なら複数・大人なら 1 本。
    public static func personReps(faces: [(embedding: [Float], date: Date?)],
                                  isChild: Bool, maxGroups: Int = 3) -> [[Float]] {
        let valid = faces.filter { !$0.embedding.isEmpty }
        guard !valid.isEmpty else { return [] }
        // 大人 / 顔が少ない / 分割無効 → 1 融合グループ。
        if !isChild || valid.count < 2 || maxGroups <= 1 {
            return fusedRep(valid.map(\.embedding)).map { [$0] } ?? []
        }
        // 撮影日昇順（nil は最古）で顔数を等分＝時期グループ。日付順なので各群が成長段階に対応。
        let sorted = valid.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        let groups = min(maxGroups, sorted.count)
        var reps: [[Float]] = []
        for g in 0..<groups {
            let lo = g * sorted.count / groups
            let hi = (g + 1) * sorted.count / groups
            guard lo < hi else { continue }
            if let r = fusedRep(sorted[lo..<hi].map(\.embedding)) { reps.append(r) }
        }
        return reps.isEmpty ? (fusedRep(valid.map(\.embedding)).map { [$0] } ?? []) : reps
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
