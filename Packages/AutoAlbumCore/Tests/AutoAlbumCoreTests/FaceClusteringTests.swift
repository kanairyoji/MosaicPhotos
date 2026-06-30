import Testing
@testable import AutoAlbumCore

@Suite("FaceClustering")
struct FaceClusteringTests {

    /// 2 つの直交方向（別人）はそれぞれ別クラスタに分かれる。
    @Test("離れた2人は2クラスタに分かれる")
    func twoPeopleSplit() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let clusters = FaceClustering.clusterAll([
            ("a1", a), ("a2", a), ("b1", b), ("b2", b),
        ], threshold: 0.5)
        #expect(clusters.count == 2)
        #expect(clusters.allSatisfy { $0.count == 2 })
    }

    /// 近い埋め込み（同一人物）は 1 クラスタに合流する。
    @Test("近い埋め込みは1クラスタに合流")
    func similarMerge() {
        let v1: [Float] = [1.0, 0.05, 0]
        let v2: [Float] = [0.98, 0.10, 0]
        let v3: [Float] = [0.95, 0.02, 0.05]
        let clusters = FaceClustering.clusterAll([
            ("1", v1), ("2", v2), ("3", v3),
        ], threshold: 0.5)
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 3)
    }

    /// しきい値を上げると、わずかに違う埋め込みも別クラスタに割れる。
    @Test("高しきい値ではわずかな差でも分かれる")
    func highThresholdSplits() {
        let v1: [Float] = [1, 0, 0]
        let v2: [Float] = [0.7, 0.7, 0]   // cos ≈ 0.707
        let clusters = FaceClustering.clusterAll([("1", v1), ("2", v2)], threshold: 0.9)
        #expect(clusters.count == 2)
    }

    /// people(minFaces:) はメンバー数下限でフィルタし、多い順に返す。
    @Test("people はメンバー数でフィルタし多い順")
    func peopleFilterAndSort() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let c: [Float] = [0, 0, 1]
        var clustering = FaceClustering(threshold: 0.5)
        for id in 0..<5 { clustering.assign(faceID: "a\(id)", embedding: a) }   // 5 faces
        for id in 0..<3 { clustering.assign(faceID: "b\(id)", embedding: b) }   // 3 faces
        clustering.assign(faceID: "c0", embedding: c)                            // 1 face
        let people = clustering.people(minFaces: 3)
        #expect(people.count == 2)
        #expect(people[0].count == 5)   // 多い順
        #expect(people[1].count == 3)
    }

    /// 正規化は向きを保ち、大きさを 1 にする。
    @Test("normalized は単位ベクトルにする")
    func normalizes() {
        let n = FaceClustering.normalized([3, 4, 0])
        #expect(abs(FaceClustering.dot(n, n) - 1) < 1e-4)
    }
}
