import Foundation
import Testing
@testable import FaceCore

/// 平均連結の夜間再クラスタ（ADR-217）。
@Suite("平均連結の再クラスタ（ADR-217）")
struct FaceAgglomerationTests {

    /// 決定的な擬似乱数（SplitMix64）。
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() % 1_000_000) / 1_000_000 }
        mutating func gaussian() -> Float {
            let u = max(unit(), 1e-6), v = unit()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// 人物 `people` 人 × 各 `perPerson` 枚。人物の中心の周りに小さく散らす（別人どうしは直交に近い）。
    /// ⚠️ 次元は 128。32 次元だと乱数の中心どうしが偶然 0.4 を超えて似て、「別人」が合流した。
    static func people(_ people: Int, perPerson: Int, dim: Int = 128, spread: Float = 0.25,
                       seed: UInt64 = 1) -> (faces: [FaceAgglomeration.Face], vectors: [String: [Float]],
                                             truth: [String: Int]) {
        var random = Random(state: seed)
        var faces: [FaceAgglomeration.Face] = []
        var vectors: [String: [Float]] = [:]
        var truth: [String: Int] = [:]
        for p in 0..<people {
            let center = FaceClustering.normalized((0..<dim).map { _ in random.gaussian() })
            for i in 0..<perPerson {
                let id = "p\(p)-\(i)"
                let v = FaceClustering.normalized(center.map { $0 + spread * random.gaussian() / Float(dim).squareRoot() })
                faces.append(.init(faceID: id, photo: id))
                vectors[id] = v
                truth[id] = p
            }
        }
        return (faces, vectors, truth)
    }

    static let config = FaceAgglomeration.Config(microThreshold: 0.55, mergeBar: 0.40)

    /// 同じ山にいる顔の組が、正解でも同じ人物か（純度）と、同じ人物が 1 つの山に集まったか。
    static func isPerfect(_ groups: [FaceAgglomeration.Group], truth: [String: Int]) -> Bool {
        var seen: [Int: Int] = [:]   // 人物 → 山の索引
        for (index, group) in groups.enumerated() {
            let people = Set(group.faceIDs.compactMap { truth[$0] })
            guard people.count <= 1 else { return false }
            if let p = people.first {
                if let other = seen[p], other != index { return false }
                seen[p] = index
            }
        }
        return true
    }

    @Test("はっきり分かれた人物は、1 人 1 つの山にまとまる")
    func separatedPeopleAreRecovered() {
        let data = Self.people(12, perPerson: 15)
        let groups = FaceAgglomeration.cluster(faces: data.faces, seeds: [],
                                               embedding: { data.vectors[$0] }, config: Self.config)
        // ⚠️ fixture の前提: 12 人ぶんの顔が本当に入っている（空でも通る assert にしない）。
        #expect(groups.flatMap(\.faceIDs).count == 12 * 15)
        #expect(groups.count == 12)
        #expect(Self.isPerfect(groups, truth: data.truth))
    }

    @Test("入れる順番を変えても、同じ分け方になる")
    func orderIndependentOnSeparatedData() {
        let data = Self.people(8, perPerson: 10)
        let base = FaceAgglomeration.cluster(faces: data.faces, seeds: [],
                                             embedding: { data.vectors[$0] }, config: Self.config)
        func partition(_ groups: [FaceAgglomeration.Group]) -> Set<Set<String>> {
            Set(groups.map { Set($0.faceIDs) })
        }
        var random = Random(state: 7)
        for _ in 0..<5 {
            var shuffled = data.faces
            for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
                shuffled.swapAt(i, Int(random.next() % UInt64(i + 1)))
            }
            let other = FaceAgglomeration.cluster(faces: shuffled, seeds: [],
                                                  embedding: { data.vectors[$0] }, config: Self.config)
            #expect(partition(other) == partition(base))
        }
    }

    @Test("近い相手だけを覚えても、全部の組で計算した結果と同じになる")
    func nearestNeighborsMatchFullPairs() {
        let data = Self.people(20, perPerson: 6, spread: 0.6, seed: 3)
        let few = FaceAgglomeration.cluster(
            faces: data.faces, seeds: [], embedding: { data.vectors[$0] },
            config: .init(microThreshold: 0.55, mergeBar: 0.40, neighbors: 10))
        let all = FaceAgglomeration.cluster(
            faces: data.faces, seeds: [], embedding: { data.vectors[$0] },
            config: .init(microThreshold: 0.55, mergeBar: 0.40, neighbors: 10_000))
        #expect(Set(few.map { Set($0.faceIDs) }) == Set(all.map { Set($0.faceIDs) }))
    }

    @Test("同じ写真の顔は、どれだけ似ていても同じ人物にしない")
    func samePhotoNeverMerges() {
        let v: [Float] = [1, 0, 0]
        let faces: [FaceAgglomeration.Face] = [
            .init(faceID: "a", photo: "X"), .init(faceID: "b", photo: "X"),
            .init(faceID: "c", photo: "Y"),
        ]
        let groups = FaceAgglomeration.cluster(faces: faces, seeds: [], embedding: { _ in v },
                                               config: Self.config)
        for group in groups {
            let photos = group.faceIDs.map { $0 == "c" ? "Y" : "X" }
            #expect(photos.count == Set(photos).count)
        }
        #expect(groups.flatMap(\.faceIDs).sorted() == ["a", "b", "c"])
    }

    @Test("種どうし（ユーザーが表明した人物）は、どれだけ似ていてもまとめない")
    func seedsNeverMergeWithEachOther() {
        let v: [Float] = [1, 0, 0]
        let vectors: [String: [Float]] = ["s1": v, "s2": v, "x": v]
        let groups = FaceAgglomeration.cluster(
            faces: [.init(faceID: "x", photo: "P3")],
            seeds: [.init(clusterID: 10, memberFaceIDs: ["s1"], photos: ["P1"]),
                    .init(clusterID: 20, memberFaceIDs: ["s2"], photos: ["P2"])],
            embedding: { vectors[$0] }, config: Self.config)
        let seedGroups = groups.filter { $0.seedID != nil }
        #expect(Set(seedGroups.compactMap(\.seedID)) == [10, 20])
        // 新しい顔はどちらか一方の種へ入る（新しい人物にはならない）。
        #expect(groups.filter { $0.seedID == nil }.allSatisfy { $0.faceIDs.isEmpty })
        #expect(seedGroups.flatMap(\.faceIDs) == ["x"])
    }

    @Test("種の写真に写っている顔は、その種へ入れない")
    func seedPhotoIsCannotLink() {
        let v: [Float] = [1, 0, 0]
        let groups = FaceAgglomeration.cluster(
            faces: [.init(faceID: "x", photo: "P1")],
            seeds: [.init(clusterID: 10, memberFaceIDs: ["s1"], photos: ["P1"])],
            embedding: { $0 == "s1" || $0 == "x" ? v : nil }, config: Self.config)
        #expect(groups.first { $0.seedID == 10 }?.faceIDs.isEmpty == true)
        #expect(groups.contains { $0.seedID == nil && $0.faceIDs == ["x"] })
    }

    @Test("負例の拒否が効く（逐次の割り当てと同じ式）")
    func negativeBlocksMerge() {
        let person: [Float] = FaceClustering.normalized([1, 0.05, 0])
        let rejected: [Float] = FaceClustering.normalized([1, 0, 0])
        // 「外した顔」とほぼ同じ顔は、その人物へ入れない。
        let negatives = [FaceClustering.NegativePair(faceCentroid: rejected, wrongCentroid: person)]
        let blocker = FaceAgglomeration.negativeBlocker(negatives: negatives, sameThreshold: 0.45)
        #expect(blocker != nil)
        let groups = FaceAgglomeration.cluster(
            faces: [.init(faceID: "x", photo: "P9")],
            seeds: [.init(clusterID: 1, memberFaceIDs: ["s"], photos: ["P1"])],
            embedding: { $0 == "s" ? person : rejected }, config: Self.config, blocked: blocker)
        #expect(groups.first { $0.seedID == 1 }?.faceIDs.isEmpty == true)
        #expect(FaceAgglomeration.negativeBlocker(negatives: [], sameThreshold: 0.45) == nil)
    }

    @Test("種の ID を保ち、新しい人物には指定の番号から ID を振る（重みは品質）")
    func materializeKeepsSeedIDs() {
        let seed = FaceClustering.Cluster(id: 7, centroid: [1, 0], sum: [2, 0], count: 2, faceIDs: [])
        let groups: [FaceAgglomeration.Group] = [
            .init(seedID: 7, faceIDs: ["a"]),
            .init(seedID: nil, faceIDs: ["b", "c"]),
            .init(seedID: nil, faceIDs: []),
        ]
        let vectors: [String: [Float]] = ["a": [1, 0], "b": [0, 1], "c": [0, 1]]
        let result = FaceAgglomeration.materialize(groups, seeds: [seed], nextID: 100,
                                                   embedding: { vectors[$0] },
                                                   quality: { $0 == "a" ? 0.5 : 1 })
        #expect(result.clusters.map(\.id) == [7, 100])
        #expect(result.assignment == ["a": 7, "b": 100, "c": 100])
        #expect(result.clusters[0].count == 3)
        #expect(result.clusters[0].sum == [2.5, 0])   // 品質 0.5 の重みで足す
        #expect(result.clusters[1].count == 2)
    }

    /// ADR-119: 「1 回ぶんに見える呼び出し」が規模に比例しないこと。数えるのは**回数**。
    @Test("顔を 4 倍にしても、1 顔あたりの埋め込みの取り出し回数は増えない")
    func embeddingDecodesStayLinear() {
        func decodesPerFace(people: Int) -> Double {
            let data = Self.people(people, perPerson: 10, seed: UInt64(people))
            var calls = 0
            let groups = FaceAgglomeration.cluster(faces: data.faces, seeds: [],
                                                   embedding: { calls += 1; return data.vectors[$0] },
                                                   config: Self.config)
            // ⚠️ fixture の前提: 人数ぶんの人物ができている（全員が 1 つに合流していない）。
            #expect(groups.count >= people / 2)
            return Double(calls) / Double(data.faces.count)
        }
        let small = decodesPerFace(people: 10)
        let large = decodesPerFace(people: 40)
        #expect(small > 0)
        #expect(large <= small)
    }
}
