import Foundation
import Testing
@testable import FaceCore

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

    // 第2パス（ADR-66・recall 回復）: フロア未満で捨てていた顔を、重心を汚さず最寄り人物へ membership 割当。
    @Test("第2パス: フロア未満の顔を重心を汚さず最寄りへ割り当てる")
    func secondPassMembershipOnly() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.4)
        let a: [Float] = [1, 0, 0]
        clustering.assign(faceID: "a0", embedding: a, quality: 1.0)
        clustering.assign(faceID: "a1", embedding: a, quality: 1.0)
        let before = clustering.clusters[0]

        // フロア未満（0.2）で主割当は未割当になる、a に近い顔（cos≈0.98 ≥ 0.55）。
        let lowFace: [Float] = [0.98, 0.2, 0]
        #expect(clustering.assign(faceID: "low", embedding: lowFace, quality: 0.2)
                == FaceClustering.unassigned)

        // 第2パス: 最寄りクラスタへ membership 割当。
        let cid = clustering.assignMembershipOnly(faceID: "low", embedding: lowFace)
        #expect(cid == before.id)
        // 重心・sum・count は不変（純度を保つ）。faceIDs にだけ加わる。
        #expect(clustering.clusters[0].sum == before.sum)
        #expect(clustering.clusters[0].count == before.count)
        #expect(clustering.clusters[0].centroid == before.centroid)
        #expect(clustering.clusters[0].faceIDs.contains("low"))
    }

    @Test("第2パス: 閾値未満（別人）は割り当てない")
    func secondPassRejectsFar() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.4)
        clustering.assign(faceID: "a0", embedding: [1, 0, 0], quality: 1.0)
        // 直交（cos 0）＝閾値 0.55 未満。
        #expect(clustering.assignMembershipOnly(faceID: "far", embedding: [0, 1, 0])
                == FaceClustering.unassigned)
    }

    @Test("第2パス: 同一写真 cannot-link で除外クラスタには入れない")
    func secondPassRespectsExclusion() {
        var clustering = FaceClustering(threshold: 0.5, qualityFloor: 0.4)
        clustering.assign(faceID: "a0", embedding: [1, 0, 0], quality: 1.0)
        let cid0 = clustering.clusters[0].id
        // 近い顔でも、そのクラスタを除外（同一写真で既に使用）していれば割り当てない。
        #expect(clustering.assignMembershipOnly(faceID: "low", embedding: [0.98, 0.2, 0],
                                                excludedClusterIDs: [cid0])
                == FaceClustering.unassigned)
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

    // MARK: - マルチプロトタイプ（B3・ADR-46）

    /// アンカー（確認済みの顔）に近ければ、重心から遠くても合流できる。
    @Test("アンカー類似で重心から遠い顔も合流（B3）")
    func prototypeRescuesFarFace() {
        // 重心は [1,0,0] 方向・アンカーは [0.6,0.8,0]（例: 若い頃の顔）。
        let anchor = FaceClustering.normalized([0.6, 0.8, 0])
        let seed = FaceClustering.Cluster(
            id: 0, centroid: [1, 0, 0], sum: [1, 0, 0], count: 1,
            faceIDs: ["a"], prototypes: [anchor])
        var clustering = FaceClustering(threshold: 0.9, qualityFloor: 0, seedClusters: [seed])
        // 重心とは cos≈0.6 だがアンカーとは cos≈1.0 → しきい値 0.9 でも合流。
        let cid = clustering.assign(faceID: "young", embedding: [0.6, 0.8, 0])
        #expect(cid == 0)
        // アンカーが無ければ新規になっていたことも確認。
        var without = FaceClustering(threshold: 0.9, qualityFloor: 0, seedClusters: [
            FaceClustering.Cluster(id: 0, centroid: [1, 0, 0], sum: [1, 0, 0], count: 1, faceIDs: ["a"])])
        #expect(without.assign(faceID: "young", embedding: [0.6, 0.8, 0]) != 0)
    }

    /// minimumNextID: 新規クラスタ ID は既存全 ID より先から振られる（B2 再クラスタ用）。
    @Test("minimumNextID で新規 ID の下限を指定できる")
    func minimumNextID() {
        var clustering = FaceClustering(threshold: 0.9, qualityFloor: 0,
                                        seedClusters: [], minimumNextID: 100)
        let cid = clustering.assign(faceID: "x", embedding: [1, 0, 0])
        #expect(cid == 100)
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

    /// 校正で bar が上がっても、**確立した人物**（アンカーあり・成熟）には本人の顔が入る（ADR-141）。
    ///
    /// ⚠️ 実機で校正が可動域の上限に張り付き、同一人物の分布の真ん中を切っていた。
    /// ユーザーが修正するほど厳しくなり、育てたアルバムが育たなくなる向きに働いていた。
    @Test("確立した人物には校正の引き上げ分を課さない")
    func establishedPersonKeepsBaseThreshold() {
        // 成熟した人物（12 顔）を作る。
        var clustering = FaceClustering(threshold: 0.40, qualityFloor: 0)
        for i in 0..<12 {
            let radians = Float(i) * 2 * .pi / 180
            clustering.assign(faceID: "m\(i)", embedding: [cos(radians), sin(radians), 0])
        }
        #expect(clustering.clusters.count == 1, "fixture: 1 人物になっていない")
        #expect(clustering.clusters[0].count == 12, "fixture: 成熟サイズに達していない")
        let personID = clustering.clusters[0].id

        // 本人の少し離れた顔（重心との cos ≈ 0.37）。校正後 0.40 には届かないが、既定 0.35 は超える。
        let radians = Float(79) * .pi / 180
        let far: [Float] = [cos(radians), sin(radians), 0]
        let sim = FaceClustering.dot(FaceClustering.normalized(far), clustering.clusters[0].centroid)
        #expect(sim > 0.35 && sim < 0.40, "fixture: 0.35〜0.40 の間になっていない（\(sim)）")

        // 校正の引き上げ分を課さない設定（アンカーあり・成熟）なら入る。
        var lenient = clustering
        lenient.baseThreshold = 0.35
        lenient.anchoredClusterIDs = [personID]
        #expect(lenient.assign(faceID: "far", embedding: far) == personID)

        // 設定しなければ従来どおり弾かれる（＝この免除が効いていることの確認）。
        var strict = clustering
        #expect(strict.assign(faceID: "far", embedding: far) != personID)
    }
}
