import Foundation
import Testing
@testable import FaceCore

/// クラスタの散らばり（ADR-210）。混入の代理指標なので、**外れ値 1 枚で跳ねない**ことと
/// 測れない（未測定）を 0 と区別することが要点。
@Suite("クラスタの散らばり（ADR-210）")
struct FaceClusterHealthTests {

    private func unit(_ angleDegrees: Float) -> [Float] {
        let r = angleDegrees * .pi / 180
        return [cos(r), sin(r), 0]
    }

    @Test("重み付き中央値は重みの累積が半分に達する値")
    func weightedMedianPicksHalfWeight() {
        // 重み 1 が 3 つ → 中央値は真ん中。
        #expect(FaceClusterHealth.weightedMedian([(0.1, 1), (0.2, 1), (0.9, 1)]) == 0.2)
        // 重みを偏らせると、重い側へ寄る。
        #expect(FaceClusterHealth.weightedMedian([(0.1, 1), (0.2, 1), (0.9, 10)]) == 0.9)
        #expect(FaceClusterHealth.weightedMedian([]) == nil)
    }

    /// ⚠️ ここが平均だと「たまたま横顔が 1 枚入っている健全な人物」と
    /// 「半分が別人のクラスタ」が同じ値になる。中央値である理由そのもの。
    @Test("外れ値 1 枚では散らばりが跳ねない（平均との違い）")
    func medianIgnoresASingleOutlier() {
        let centroid = unit(0)
        var members = (0..<9).map { (embedding: unit(Float($0)), quality: Float(1)) }
        members.append((unit(90), 1))   // 直交＝距離 1.0 の外れ値
        let spread = FaceClusterHealth.spread(members: members, centroid: centroid)
        #expect(spread != nil)
        #expect(spread! < 0.01)         // 中央値はほぼ 0 のまま
    }

    @Test("過半が遠ければ散らばりは大きくなる")
    func majorityFarMakesSpreadLarge() {
        let centroid = unit(0)
        let members = (0..<10).map { i in
            (embedding: unit(i < 6 ? 80 : 2), quality: Float(1))
        }
        let spread = FaceClusterHealth.spread(members: members, centroid: centroid)
        #expect(spread != nil && spread! > 0.5)
    }

    @Test("品質が低い顔は散らばりの判断を支配しない（重心の作り方と同じ規則）")
    func lowQualityIsDownWeighted() {
        let centroid = unit(0)
        var members = (0..<5).map { _ in (embedding: unit(1), quality: Float(1)) }
        // ぼけ顔を 5 枚足しても、重みが軽ければ中央値は動かない。
        members += (0..<5).map { _ in (embedding: unit(89), quality: Float(0.05)) }
        let spread = FaceClusterHealth.spread(members: members, centroid: centroid)!
        #expect(spread < 0.01)
    }


    @Test("監査の順番は散らばりの大きい順・同値はクラスタ ID の小さい順（決定的）")
    func auditOrderIsDeterministic() {
        let items = [(id: 3, spread: Float?(0.5)), (id: 1, spread: Float?(0.5)),
                     (id: 2, spread: Float?(0.9)), (id: 4, spread: nil)]
        let ordered = FaceClusterHealth.auditOrder(items, spread: { $0.spread },
                                                   clusterID: { $0.id })
        #expect(ordered.map(\.id) == [2, 1, 3, 4])
    }

    @Test("メンバーが空なら nil（『測っていない』と『0』を区別する）")
    func emptyIsNotZero() {
        #expect(FaceClusterHealth.spread(members: [], centroid: unit(0)) == nil)
    }
}
