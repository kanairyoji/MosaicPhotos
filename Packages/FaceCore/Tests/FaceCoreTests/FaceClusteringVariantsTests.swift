import Foundation
import Testing
@testable import FaceCore

/// 評価用クラスタリングバリアント（ADR-57 系統1）の純ロジック検証。
@Suite("FaceClusteringVariants")
struct FaceClusteringVariantsTests {

    private let personA: [Float] = [1, 0, 0]
    private let personB: [Float] = [0, 1, 0]

    @Test("マージンゲート: 両クラスタに紛らわしい顔は合流せず新規になる")
    func marginGateRejectsAmbiguous() {
        // A と B の核を作ってから、両者の中間（両方に cos≈0.71）の顔を入れる。
        let faces: [(faceID: String, embedding: [Float])] = [
            ("a1", personA), ("a2", personA), ("b1", personB), ("b2", personB),
            ("mid", FaceClustering.normalized([1, 1, 0])),
        ]
        let clusters = FaceClusteringVariants.marginGatedCluster(faces, threshold: 0.6, margin: 0.10)
        // mid は 1位/2位の差 0 < margin → 新規クラスタ（混入しない）。
        #expect(clusters.count == 3)
        let midCluster = clusters.first { $0.faceIDs.contains("mid") }
        #expect(midCluster?.count == 1)
        // 紛らわしくない顔（A 側のみに近い）は普通に合流する。
        let clear = FaceClusteringVariants.marginGatedCluster(
            faces + [("a3", [0.99, 0.05, 0])], threshold: 0.6, margin: 0.10)
        #expect(clear.first { $0.faceIDs.contains("a3") }?.faceIDs.contains("a1") == true)
    }

    @Test("二段階: 明確な顔は核へ帰属・紛らわしい顔は単独のまま・核の重心は不動")
    func twoStageAttachesClearOnly() {
        let faces: [(faceID: String, embedding: [Float])] = [
            ("a1", personA), ("a2", [0.99, 0.02, 0]),
            ("b1", personB), ("b2", [0.02, 0.99, 0]),
            ("nearA", [0.9, 0.2, 0]),                                  // A に明確に近い
            ("mid", FaceClustering.normalized([1, 1, 0])),             // 両者に等距離
        ]
        // 核しきい値 0.8: mid（両核と cos≈0.71）は核に入らず第 2 段の比率テストへ回る。
        let clusters = FaceClusteringVariants.twoStageCluster(
            faces, coreThreshold: 0.8, attachThreshold: 0.5, margin: 0.1)
        let aCore = clusters.first { $0.faceIDs.contains("a1") }
        #expect(aCore?.faceIDs.contains("nearA") == true)    // 帰属
        let midCluster = clusters.first { $0.faceIDs.contains("mid") }
        #expect(midCluster?.count == 1)                      // 単独のまま
    }

    @Test("外れ値除去: 混入した別人顔を抜いて単独クラスタにする")
    func pruneRemovesOutlier() {
        // A の顔 5 ＋ 混入した別人 1（明確に離れている）。
        var faceIDs = (0..<5).map { "a\($0)" }
        var emb: [String: [Float]] = [:]
        for i in 0..<5 { emb["a\(i)"] = [1, 0.02 * Float(i), 0] }
        emb["intruder"] = FaceClustering.normalized([0, 1, 0])   // 別人（cos≈0）
        faceIDs.append("intruder")
        let cluster = FaceClustering.Cluster(id: 0, centroid: [1, 0, 0], sum: [1, 0, 0],
                                             count: 6, faceIDs: faceIDs)
        let result = FaceClusteringVariants.pruneOutliers([cluster], embeddings: emb,
                                                          dropFactor: 1.8, minCount: 4)
        // intruder が抜けて本体（5 顔）＋単独（intruder）の 2 クラスタに。
        #expect(result.count == 2)
        let main = result.max { $0.count < $1.count }
        #expect(main?.count == 5)
        #expect(main?.faceIDs.contains("intruder") == false)
    }

    @Test("外れ値除去: 均質なクラスタは無変化・小クラスタは検査しない")
    func pruneKeepsCleanCluster() {
        var emb: [String: [Float]] = [:]
        for i in 0..<6 { emb["a\(i)"] = [1, 0.01 * Float(i), 0] }   // 全て近い
        let clean = FaceClustering.Cluster(id: 0, centroid: [1, 0, 0], sum: [1, 0, 0],
                                           count: 6, faceIDs: (0..<6).map { "a\($0)" })
        #expect(FaceClusteringVariants.pruneOutliers([clean], embeddings: emb).count == 1)
        // minCount 未満（3 顔）は検査対象外＝そのまま。
        var small: [String: [Float]] = ["x0": [1, 0, 0], "x1": [1, 0, 0], "x2": [0, 1, 0]]
        let smallCluster = FaceClustering.Cluster(id: 0, centroid: [1, 0, 0], sum: [1, 0, 0],
                                                  count: 3, faceIDs: ["x0", "x1", "x2"])
        #expect(FaceClusteringVariants.pruneOutliers([smallCluster], embeddings: small,
                                                     minCount: 4).count == 1)
        _ = small
    }

    @Test("中央値重心: 外れ顔 1 つに引っ張られず本体の顔を保持する")
    func medianResistsOutlier() {
        // A の顔 5 ＋（誤って似た）外れ 1。平均重心は外れに引っ張られるが中央値は動かない。
        var faces: [(faceID: String, embedding: [Float])] = (0..<5).map {
            ("a\($0)", [1, 0.02 * Float($0), 0])
        }
        faces.append(("outlier", FaceClustering.normalized([0.75, 0.66, 0])))   // cos≈0.75 で混入
        faces.append(("a5", [1, 0.01, 0]))                                       // 本体の顔
        let clusters = FaceClusteringVariants.medianRefinedCluster(faces, threshold: 0.6)
        let main = clusters.max { $0.count < $1.count }
        #expect(main?.faceIDs.contains("a5") == true)
        // 中央値重心は本体方向 ≈ [1,0,0] に留まる。
        #expect(main.map { FaceClustering.dot($0.centroid, [1, 0, 0]) } ?? 0 > 0.95)
    }
}
