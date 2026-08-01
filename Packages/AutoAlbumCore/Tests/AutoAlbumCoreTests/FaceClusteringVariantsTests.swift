import Foundation
import Testing
@testable import AutoAlbumCore

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
