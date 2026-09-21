import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// **顔クラスタリングの不変条件**（ADR-210）。
///
/// ⚠️ これまでの顔まわりのテストは「この入力でこう動く」を固定するものが中心で、
/// **どんな入力でも壊れてはいけないこと**を言う場所が無かった。実際に踏んだ不具合
/// （重心の記録ずれ・付け替えで人物が消える・負例 1 件でアルバムが激減）は、
/// どれも個別の事例テストをすり抜けている。ここは入力をランダムに振って、
/// 崩れてはいけない性質だけを確かめる。
///
/// ⚠️ 乱数は**固定シード**（SplitMix64）。落ちたときに再現できないテストは、
/// バグを隠す（ADR-119「フレーキーなテストはバグを隠す」）。
@Suite("顔クラスタリングの不変条件（ADR-210）")
struct FaceInvariantTests {

    /// 決定的な擬似乱数（SplitMix64）。
    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func float(_ range: ClosedRange<Float>) -> Float {
            let unit = Float(next() % 10_000) / 10_000
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private func vector(_ rng: inout RNG, around axis: Int, spread: Float, dim: Int = 8) -> [Float] {
        (0..<dim).map { i in (i == axis ? 1.0 : 0.0) + rng.float(-spread...spread) }
    }

    // MARK: - 1. 重心の記録は、実際に足したものと必ず一致する

    /// ⚠️ **実際に踏んだ形**: `sum` は品質フロア以上の顔だけで作られているのに、
    /// 行は「全員が寄与した」と記録していた。数枚外すと `count` が尽きて人物が消える。
    /// どんな add/remove/merge の列のあとでも、記録と実体が一致することを固定する。
    @Test("どんな追加・削除・統合の列でも sum と count は実体と一致する")
    func centroidRecordAlwaysMatchesReality() {
        for seed in 0..<20 {
            var rng = RNG(state: UInt64(seed) &* 2_654_435_761 &+ 1)
            var sum = [Float](repeating: 0, count: 8)
            var count = 0
            /// 「いま sum に入っている」と自分で記録しているもの。
            var contributing: [(vector: [Float], quality: Float)] = []

            for _ in 0..<40 {
                switch rng.int(3) {
                case 0:   // 足す
                    let v = vector(&rng, around: rng.int(3), spread: 0.4)
                    let quality = rng.float(0.05...1.0)
                    let added = FaceClustering.adding(v, toSum: sum, count: count, quality: quality)
                    sum = added.sum
                    count = added.count
                    contributing.append((v, quality))
                case 1 where !contributing.isEmpty:   // 引く
                    let index = rng.int(contributing.count)
                    let member = contributing[index]
                    guard let removed = FaceClustering.removing(member.vector, fromSum: sum,
                                                                count: count,
                                                                quality: member.quality) else {
                        continue   // 最後の 1 枚（クラスタ削除の合図）は実体側も触らない
                    }
                    sum = removed.sum
                    count = removed.count
                    contributing.remove(at: index)
                default:   // 別クラスタを統合する
                    var otherSum = [Float](repeating: 0, count: 8)
                    var otherCount = 0
                    var others: [(vector: [Float], quality: Float)] = []
                    for _ in 0..<(1 + rng.int(3)) {
                        let v = vector(&rng, around: rng.int(3), spread: 0.4)
                        let quality = rng.float(0.05...1.0)
                        let added = FaceClustering.adding(v, toSum: otherSum, count: otherCount,
                                                          quality: quality)
                        otherSum = added.sum
                        otherCount = added.count
                        others.append((v, quality))
                    }
                    let merged = FaceClustering.merging(sumA: sum, countA: count,
                                                        sumB: otherSum, countB: otherCount)
                    sum = merged.sum
                    count = merged.count
                    contributing += others
                }

                // 記録（sum/count）と、寄与していると自分が言っているものが一致するか。
                let state = FaceCentroidAudit.ClusterState(
                    clusterID: 1, storedSum: sum, storedCount: count,
                    members: contributing.enumerated().map {
                        .init(faceID: "f\($0.offset)", quality: $0.element.quality,
                              contributes: true)
                    })
                let embeddings = Dictionary(uniqueKeysWithValues:
                    contributing.enumerated().map { ("f\($0.offset)", $0.element.vector) })
                let findings = FaceCentroidAudit.check(clusters: [state],
                                                       embedding: { embeddings[$0] })
                #expect(findings.isEmpty, "seed \(seed): \(FaceCentroidAudit.summary(findings))")
            }
        }
    }

    // MARK: - 2. 第2パスは重心を 1 ビットも動かさない

    /// 「純度は不変」（ADR-66）は言葉の約束ではなく、検査できる性質。
    @Test("第2パスの前後で sum・count・重心は完全に同一")
    func secondPassNeverTouchesTheCentroid() {
        for seed in 0..<10 {
            var rng = RNG(state: UInt64(seed) &* 88_172_645_463_325_252 &+ 7)
            var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.4)
            for i in 0..<30 {
                clustering.assign(faceID: "f\(i)", embedding: vector(&rng, around: i % 3, spread: 0.2),
                                  quality: rng.float(0.4...1.0))
            }
            let before = clustering.clusters.map { ($0.id, $0.sum, $0.count, $0.centroid) }
            for i in 0..<20 {
                _ = clustering.assignMembershipOnly(
                    faceID: "low\(i)", embedding: vector(&rng, around: i % 3, spread: 0.6))
            }
            let after = clustering.clusters.map { ($0.id, $0.sum, $0.count, $0.centroid) }
            #expect(before.count == after.count)
            for (a, b) in zip(before, after) {
                #expect(a.0 == b.0)
                #expect(a.1 == b.1)   // sum はバイト単位で同一
                #expect(a.2 == b.2)
                #expect(a.3 == b.3)
            }
        }
    }

    // MARK: - 3. 重心を凍結したクラスタは所属だけ受け取る

    @Test("凍結したクラスタへ入った顔は『足した』と報告されない")
    func frozenClusterAcceptsMembershipOnly() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.1,
                                        seedClusters: [
                                            .init(id: 1, centroid: [1, 0, 0], sum: [1, 0, 0],
                                                  count: 12, faceIDs: [], prototypes: [],
                                                  centroidFrozen: true)
                                        ], minimumNextID: 2)
        let before = clustering.clusters[0]
        let placed = clustering.place(faceID: "x", embedding: [0.99, 0.1, 0], quality: 1)
        #expect(placed.clusterID == 1)
        #expect(placed.contributed == false)
        #expect(clustering.clusters[0].sum == before.sum)
        #expect(clustering.clusters[0].count == before.count)
        #expect(clustering.clusters[0].centroid == before.centroid)
        #expect(clustering.clusters[0].faceIDs.contains("x"))
    }

    // MARK: - 4. はっきり分かれているデータなら、順序で答えが変わらない

    /// 逐次貪欲は原理的に順序依存だが、**曖昧でないデータでは順序に依らない**はず。
    /// ここが崩れるなら、しきい値やマージンの効き方に見落としがある。
    @Test("十分に離れた人物どうしなら、並べ替えても同じクラスタになる")
    func unambiguousDataIsOrderIndependent() {
        for seed in 0..<10 {
            var rng = RNG(state: UInt64(seed) &+ 991)
            var faces: [(faceID: String, embedding: [Float])] = []
            for person in 0..<4 {
                for i in 0..<8 {
                    faces.append(("p\(person)f\(i)",
                                  vector(&rng, around: person, spread: 0.05)))
                }
            }
            func grouping(_ input: [(faceID: String, embedding: [Float])]) -> Set<Set<String>> {
                let clusters = FaceClustering.clusterAll(input, threshold: 0.5, qualityFloor: 0.1)
                return Set(clusters.map { Set($0.faceIDs) })
            }
            let forward = grouping(faces)
            #expect(forward.count == 4)
            #expect(grouping(faces.reversed()) == forward)
            #expect(grouping(faces.sorted { $0.faceID > $1.faceID }) == forward)
        }
    }

    // MARK: - 5. 校正はどんなサンプルでも暴れない

    /// ⚠️ 実機で校正値が可動域の上限に張り付き、「直すほど厳しくなる」状態になった（ADR-149）。
    /// どんな入力でも可動域を出ず、分離しないデータでは既定値のままであることを固定する。
    @Test("校正は可動域を出ない・分離しないデータでは既定値のまま")
    func calibrationIsAlwaysBounded() {
        for seed in 0..<30 {
            var rng = RNG(state: UInt64(seed) &* 6_364_136_223_846_793_005 &+ 13)
            let positive = (0..<(8 + rng.int(40))).map { _ in rng.float(0...1) }
            let negative = (0..<(8 + rng.int(40))).map { _ in rng.float(0...1) }
            let calibrated = FaceCalibration.calibratedThreshold(
                positive: positive, negative: negative, fallback: 0.35)
            #expect(FaceCalibration.clampRange.contains(calibrated) || calibrated == 0.35)
        }
        // 完全に重なった分布（AUC ≒ 0.5）＝境界を作ってはいけない。
        let overlapping = (0..<40).map { Float($0 % 20) / 20 }
        #expect(FaceCalibration.calibratedThreshold(positive: overlapping, negative: overlapping,
                                                    fallback: 0.35) == 0.35)
    }
}
