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

    // MARK: - Reassign（付け替えの重心演算）

    /// adding は assign と同じ正規化規則（正規化してから加算）。
    @Test("adding は正規化してから sum に加算する")
    func addingNormalizesFirst() {
        // 大きさ 5 のベクトルでも、単位ベクトルとして足される。
        let (sum, count) = FaceClustering.adding([3, 4, 0], toSum: [0, 0, 0], count: 0)
        #expect(count == 1)
        #expect(abs(sum[0] - 0.6) < 1e-4)
        #expect(abs(sum[1] - 0.8) < 1e-4)
    }

    /// add → remove の往復で sum/count が元に戻る（付け替えを繰り返しても重心が壊れない）。
    @Test("adding→removing の往復で重心が元に戻る")
    func addRemoveRoundtrip() {
        let base: [Float] = [1, 0, 0]
        let extra: [Float] = [0, 3, 4]   // 非正規化で与える
        let added = FaceClustering.adding(extra, toSum: base, count: 1)
        #expect(added.count == 2)
        let removed = FaceClustering.removing(extra, fromSum: added.sum, count: added.count)
        #expect(removed != nil)
        #expect(removed?.count == 1)
        for i in 0..<3 {
            #expect(abs((removed?.sum[i] ?? -1) - base[i]) < 1e-4)
        }
    }

    /// 統合＝生合計の加算・件数の合算。1 顔ずつ adding したのと等価（重心が加重平均になる）。
    @Test("merging は sum を加算し count を合算する")
    func mergingCombinesSums() {
        let a = FaceClustering.merging(sumA: [1, 0, 0], countA: 2, sumB: [0, 2, 0], countB: 3)
        #expect(a.count == 5)
        #expect(a.sum == [1, 2, 0])
        // 1 顔ずつ足したのと一致（正規化済みベクトルを sum に積む規則）。
        let step1 = FaceClustering.adding([1, 0, 0], toSum: [0, 0, 0], count: 0)   // (1,0,0),1
        let step2 = FaceClustering.adding([0, 1, 0], toSum: step1.sum, count: step1.count) // (1,1,0),2
        let merged = FaceClustering.merging(sumA: step1.sum, countA: step1.count,
                                            sumB: FaceClustering.adding([0, 1, 0], toSum: [0, 0, 0], count: 0).sum,
                                            countB: 1)
        #expect(merged.sum == step2.sum)
        #expect(merged.count == step2.count)
    }

    /// 次元不一致（壊れた sum）でも件数は合算し、多い方の sum を残す（安全側）。
    @Test("merging は次元不一致でも件数を合算する")
    func mergingDimensionMismatch() {
        let r = FaceClustering.merging(sumA: [1, 0, 0], countA: 5, sumB: [0, 1], countB: 2)
        #expect(r.count == 7)
        #expect(r.sum == [1, 0, 0])   // 件数の多い A 側を残す
    }

    /// 最後の 1 顔を除くと nil（クラスタ削除の合図）。
    @Test("removing は最後の1顔で nil を返す")
    func removingLastFaceSignalsDeletion() {
        #expect(FaceClustering.removing([1, 0, 0], fromSum: [1, 0, 0], count: 1) == nil)
        #expect(FaceClustering.removing([1, 0, 0], fromSum: [1, 0, 0], count: 0) == nil)
    }

    // MARK: - 品質ゲート（ADR-45）

    /// 品質フロア未満の顔は割り当てられず -1（未割当）を返す＝重心を汚さない。
    @Test("品質フロア未満は未割当(-1)")
    func lowQualityUnassigned() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.3)
        let cid = clustering.assign(faceID: "blurry", embedding: [1, 0, 0], quality: 0.1)
        #expect(cid == FaceClustering.unassigned)
        #expect(clustering.clusters.isEmpty)   // 新規クラスタも作らない
    }

    /// 品質重み: 高品質の顔ほど重心を強く引く（低品質の外れ顔が重心を動かしにくい）。
    @Test("品質重みで重心が高品質側に寄る")
    func qualityWeightedCentroid() {
        var clustering = FaceClustering(threshold: -1, qualityFloor: 0)   // 必ず 1 クラスタに集める
        clustering.assign(faceID: "hi", embedding: [1, 0, 0], quality: 1.0)
        clustering.assign(faceID: "lo", embedding: [0, 1, 0], quality: 0.1)   // 低品質の別方向
        // 重心は高品質側 [1,0,0] に大きく寄る（x >> y）。
        let c = clustering.clusters[0].centroid
        #expect(c[0] > c[1])
        #expect(c[0] > 0.9)
    }

    // MARK: - 負例エグゼンプラ（ADR-45）

    /// 負例: 「A は X の人ではない」と記録済みなら、A に似た顔は X へ入らず新規/次点になる。
    @Test("負例で同じ誤りを繰り返さない")
    func negativeExemplarRejects() {
        // クラスタ X = [1,0,0] 方向。
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0)
        clustering.assign(faceID: "x1", embedding: [1, 0, 0])
        clustering.assign(faceID: "x2", embedding: [0.98, 0.03, 0])
        let xCentroid = clustering.clusters[0].centroid

        // 「[0.9,0.1,0] のような顔は X ではない」という負例。
        let negatives = [FaceClustering.NegativePair(
            faceCentroid: FaceClustering.normalized([0.9, 0.1, 0]),
            wrongCentroid: xCentroid)]

        // X に近い（本来なら合流する）新顔だが、負例に該当 → X へは入らず新規クラスタになる。
        let cid = clustering.assign(faceID: "new", embedding: [0.9, 0.1, 0],
                                    quality: 1, negatives: negatives)
        #expect(cid != clustering.clusters[0].id)
        #expect(clustering.clusters.count == 2)
    }

    /// 負例に無関係な顔は従来どおり合流する（過剰拒否しない）。
    @Test("負例に無関係な顔は普通に合流")
    func negativeDoesNotOverReject() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0)
        clustering.assign(faceID: "x1", embedding: [1, 0, 0])
        let xCentroid = clustering.clusters[0].centroid
        // 別人 [0,1,0] についての負例（今回の入力とは無関係）。
        let negatives = [FaceClustering.NegativePair(
            faceCentroid: FaceClustering.normalized([0, 1, 0]),
            wrongCentroid: xCentroid)]
        let cid = clustering.assign(faceID: "x2", embedding: [0.99, 0.02, 0],
                                    quality: 1, negatives: negatives)
        #expect(cid == clustering.clusters[0].id)   // 同一人物なので合流
        #expect(clustering.clusters.count == 1)
    }

    /// 次元不一致の埋め込みは sum を壊さない（count のみ増減）。
    @Test("次元不一致でも sum を壊さない")
    func dimensionMismatchIsSafe() {
        let (sum, count) = FaceClustering.adding([1, 0], toSum: [0, 0, 0], count: 2)
        #expect(sum == [0, 0, 0])
        #expect(count == 3)
        let removed = FaceClustering.removing([1, 0], fromSum: [5, 0, 0], count: 3)
        #expect(removed?.sum == [5, 0, 0])
        #expect(removed?.count == 2)
    }
}
