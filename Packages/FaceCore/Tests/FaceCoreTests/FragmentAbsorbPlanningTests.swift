import Foundation
import Testing
@testable import FaceCore

/// **断片の自動吸収の判定**（純ロジック・ADR-154/155/162）。
///
/// 以前は `FaceStore.absorbFragments`（分岐 46＝リポジトリ全体で最大）の中に
/// 収集・選別・判定・適用が混ざっていて、SwiftData を立てないと 1 つも試せなかった。
/// ここは判定と選別だけを、組み合わせで確かめる。
@Suite("断片の自動吸収: 判定")
struct FragmentAbsorbPlanningTests {

    private typealias Planning = FragmentAbsorbPlanning

    private func neighbour(_ id: Int, _ v: [Float], target: Bool,
                           refKeys: Set<String> = []) -> Planning.Neighbour {
        Planning.Neighbour(clusterID: id, centroid: FaceClustering.normalized(v),
                           isTarget: target, refKeys: refKeys)
    }

    private func decide(_ centroid: [Float], _ neighbours: [Planning.Neighbour],
                        refKeys: Set<String> = [], bar: Float = 0.6, margin: Float = 0.05,
                        blocked: Set<String> = []) -> Planning.Decision {
        Planning.decide(fragmentID: 99, centroid: FaceClustering.normalized(centroid),
                        refKeys: refKeys, neighbours: neighbours, negatives: [],
                        bar: bar, margin: margin, negativeSameThreshold: 0.5,
                        isBlockedPair: { a, b in blocked.contains(a < b ? "\(a)-\(b)" : "\(b)-\(a)") })
    }

    // MARK: - 選別（誰が断片で、誰が吸収先か）

    @Test("断片は「小さく・無名・アンカーなし・束ねなし」のときだけ")
    func fragmentSelection() {
        let plain = Planning.Shape(photos: 2, hasName: false, isGrouped: false, hasAnchor: false)
        #expect(Planning.isFragment(plain, maxPhotos: 2))
        #expect(!Planning.isFragment(.init(photos: 3, hasName: false, isGrouped: false, hasAnchor: false),
                                     maxPhotos: 2), "上限を超えたら断片ではない")
        #expect(!Planning.isFragment(.init(photos: 0, hasName: false, isGrouped: false, hasAnchor: false),
                                     maxPhotos: 2), "写真が無いクラスタは対象外")
        // ⚠️ 利用者が表明したものは機械が動かさない（ADR-152/153）。
        #expect(!Planning.isFragment(.init(photos: 1, hasName: true, isGrouped: false, hasAnchor: false),
                                     maxPhotos: 2), "名前があるものを寄せてはいけない")
        #expect(!Planning.isFragment(.init(photos: 1, hasName: false, isGrouped: false, hasAnchor: true),
                                     maxPhotos: 2), "確認済みの顔があるものを寄せてはいけない")
        #expect(!Planning.isFragment(.init(photos: 1, hasName: false, isGrouped: true, hasAnchor: false),
                                     maxPhotos: 2), "束ねに入っているものを寄せてはいけない")
    }

    @Test("吸収先は「確立した人物」だけ（表明あり × 一定枚数以上）")
    func targetSelection() {
        #expect(Planning.isTarget(.init(photos: 5, hasName: true, isGrouped: false, hasAnchor: false),
                                  minPhotos: 3))
        #expect(Planning.isTarget(.init(photos: 5, hasName: false, isGrouped: false, hasAnchor: true),
                                  minPhotos: 3), "名前が無くても確認済みの顔があれば吸収先")
        #expect(!Planning.isTarget(.init(photos: 2, hasName: true, isGrouped: false, hasAnchor: false),
                                   minPhotos: 3), "小さい人物は吸収先にしない")
        #expect(!Planning.isTarget(.init(photos: 9, hasName: false, isGrouped: false, hasAnchor: false),
                                   minPhotos: 3), "表明の無い大きな塊は吸収先にしない")
    }

    /// 「上限を上げれば寄せられた分」＝次に上限をどこへ置くかの材料（ADR-155）。
    @Test("上限だけが理由の塊を数える")
    func tooBigSelection() {
        #expect(Planning.isTooBigToAbsorb(.init(photos: 3, hasName: false, isGrouped: false, hasAnchor: false),
                                          maxPhotos: 2, minPhotos: 5))
        #expect(!Planning.isTooBigToAbsorb(.init(photos: 2, hasName: false, isGrouped: false, hasAnchor: false),
                                           maxPhotos: 2, minPhotos: 5), "それは断片（上限内）")
        #expect(!Planning.isTooBigToAbsorb(.init(photos: 5, hasName: false, isGrouped: false, hasAnchor: false),
                                           maxPhotos: 2, minPhotos: 5), "吸収先の大きさに達している")
        #expect(!Planning.isTooBigToAbsorb(.init(photos: 3, hasName: true, isGrouped: false, hasAnchor: false),
                                           maxPhotos: 2, minPhotos: 5), "表明があるものは元から対象外")
    }

    // MARK: - 判定

    @Test("紛らわしくなければ、いちばん近い吸収先へ寄せる")
    func absorbsClearFragment() {
        let d = decide([1, 0, 0], [neighbour(1, [0.99, 0.1, 0], target: true),
                                   neighbour(2, [0, 1, 0], target: true)])
        #expect(d.outcome == .absorb(into: 1))
        #expect(d.cleanSimilarity != nil, "バー以外の条件を通ったので分布に数える")
    }

    @Test("吸収先が 1 つも無ければ見送る")
    func skipsWithoutTarget() {
        let d = decide([1, 0, 0], [neighbour(2, [0.99, 0.1, 0], target: false)])
        #expect(d.outcome == .skip(.belowBar))
        #expect(d.cleanSimilarity == nil)
    }

    /// ⚠️ 兄弟・親子で取り違えないための保険（ADR-154）。
    @Test("2 位が近すぎるときは人に尋ねる")
    func skipsAmbiguous() {
        let d = decide([1, 0, 0], [neighbour(1, [0.99, 0.1, 0], target: true),
                                   neighbour(2, [0.98, 0.12, 0], target: false)])
        #expect(d.outcome == .skip(.marginal))
        #expect(d.cleanSimilarity == nil, "紛らわしい分は「バーを下げれば寄る」に数えない")
    }

    @Test("同じ写真に一緒に写っているなら寄せない")
    func skipsSamePhoto() {
        let d = decide([1, 0, 0], [neighbour(1, [0.99, 0.1, 0], target: true, refKeys: ["L-a"])],
                       refKeys: ["L-a"])
        #expect(d.outcome == .skip(.blocked))
    }

    @Test("「別人」と記録された対は寄せない")
    func skipsBlockedPair() {
        let d = decide([1, 0, 0], [neighbour(1, [0.99, 0.1, 0], target: true)],
                       blocked: ["1-99"])
        #expect(d.outcome == .skip(.blocked))
    }

    /// ⚠️ **判定の順番を変えない**（記録の内訳が意味を保つ）。バー → マージン → 汚れ。
    /// 紛らわしくもあり汚れてもいる断片は、**マージンで落ちたと数える**。
    @Test("落ちる理由は、先に当たった条件で数える")
    func reasonFollowsTheFixedOrder() {
        let d = decide([1, 0, 0], [neighbour(1, [0.99, 0.1, 0], target: true, refKeys: ["L-a"]),
                                   neighbour(2, [0.98, 0.12, 0], target: false)],
                       refKeys: ["L-a"])
        #expect(d.outcome == .skip(.marginal), "汚れより先にマージンで落ちる")
    }

    /// ⚠️ **バーで落ちた断片も、バー以外の条件は評価する**（ADR-162）。
    /// 「バーを 0.65 にしたら何件寄るか」を実測で決めるための材料。
    @Test("バーに届かなくても、他が綺麗なら分布には数える")
    func countsCleanFragmentsBelowTheBar() {
        let d = decide([1, 0, 0], [neighbour(1, [0.8, 0.6, 0], target: true)], bar: 0.99)
        #expect(d.outcome == .skip(.belowBar))
        #expect(d.cleanSimilarity != nil, "バーを下げれば寄る分を数えていない")
    }

    @Test("見送りの内訳を数える")
    func skipCounts() {
        var counts = Planning.SkipCounts()
        counts.record(.belowBar); counts.record(.belowBar); counts.record(.marginal)
        #expect(counts.belowBar == 2)
        #expect(counts.marginal == 1)
        #expect(counts.blocked == 0)
        #expect(counts.total == 3)
    }
}

/// **レビューカードの候補選び**（純ロジック・ADR-46/123/152）。
@Suite("レビュー候補の選び方")
struct ReviewCandidatePlanningTests {

    private func unit(_ v: [Float]) -> [Float] { FaceClustering.normalized(v) }

    private func candidates(focus: [Int], others: [Int], centroid: [Int: [Float]],
                            name: [Int: String] = [:], bandFloor: Float = 0.5,
                            scanLimit: Int = 120,
                            notSame: Set<String> = []) -> [ReviewCandidatePlanning.Pair] {
        ReviewCandidatePlanning.mergeCandidates(
            focus: focus, others: others, centroid: centroid, name: name,
            bandFloor: bandFloor, scanLimit: scanLimit,
            isMarkedNotSame: { a, b in notSame.contains(a < b ? "\(a)-\(b)" : "\(b)-\(a)") },
            namesConflict: { a, b in
                guard let a, !a.isEmpty, let b, !b.isEmpty else { return false }
                return a != b
            })
    }

    /// ⚠️ **片側は必ず基準**（ADR-123）。基準を絞ることで探索が人物数² にならない。
    @Test("基準を含まない対は候補にしない")
    func everyPairTouchesAFocusCluster() {
        let c = [1: unit([1, 0, 0]), 2: unit([1, 0.05, 0]), 3: unit([1, 0.1, 0])]
        let pairs = candidates(focus: [1], others: [1, 2, 3], centroid: c)
        #expect(pairs.allSatisfy { $0.a == 1 }, "基準の居ない対が混ざっている: \(pairs)")
        #expect(pairs.count == 2)
    }

    @Test("帯に届かない対は出さない")
    func belowTheBandIsDropped() {
        let c = [1: unit([1, 0, 0]), 2: unit([0, 1, 0])]
        #expect(candidates(focus: [1], others: [1, 2], centroid: c, bandFloor: 0.5).isEmpty)
    }

    /// 「別人」と答えた対・同一写真で統合できない対（ADR-152）。
    @Test("別人と記録済みの対は二度と出さない")
    func notSamePairsAreDropped() {
        let c = [1: unit([1, 0, 0]), 2: unit([1, 0.05, 0])]
        #expect(candidates(focus: [1], others: [1, 2], centroid: c, notSame: ["1-2"]).isEmpty)
    }

    /// 利用者が別々の名前を付けた人物どうしは、既に「別人」と表明されている。
    @Test("別々の名前が付いた人物どうしは出さない")
    func differentNamesAreDropped() {
        let c = [1: unit([1, 0, 0]), 2: unit([1, 0.05, 0])]
        #expect(candidates(focus: [1], others: [1, 2], centroid: c,
                           name: [1: "太郎", 2: "次郎"]).isEmpty)
        #expect(candidates(focus: [1], others: [1, 2], centroid: c,
                           name: [1: "太郎", 2: ""]).count == 1, "無名は衝突しない")
    }

    /// ⚠️ **打ち切りは並べ替えの後**。先に切ると「たまたま先に見つかった対」が残り、
    /// いちばん尋ねる価値のある（近い）対が落ちる。
    @Test("上限で切るのは、近い順に並べた後")
    func limitKeepsTheClosestPairs() {
        var c = [0: unit([1, 0, 0])]
        for i in 1...5 { c[i] = unit([1, Float(i) * 0.05, 0]) }
        let pairs = candidates(focus: [0], others: Array(0...5), centroid: c, scanLimit: 2)
        #expect(pairs.count == 2)
        #expect(pairs.map(\.b) == [1, 2], "いちばん近い 2 対が残っていない: \(pairs.map(\.b))")
        #expect(pairs[0].sim >= pairs[1].sim, "降順になっていない")
    }

    @Test("重心の無いクラスタは黙って飛ばす")
    func clustersWithoutCentroidAreSkipped() {
        let c = [1: unit([1, 0, 0])]           // 2 の重心が無い
        #expect(candidates(focus: [1], others: [1, 2], centroid: c).isEmpty)
        #expect(candidates(focus: [2], others: [1, 2], centroid: c).isEmpty)
    }
}
