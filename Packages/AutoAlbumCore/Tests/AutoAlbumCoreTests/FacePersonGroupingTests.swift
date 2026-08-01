import Foundation
import Testing
@testable import AutoAlbumCore

/// 2 階層の人物モデル（人物=複数クラスタの束）の帰属ロジック（ADR-61）。
@Suite("FacePersonGrouping")
struct FacePersonGroupingTests {

    @Test("成長顔は融合重心では外れるが、時期別クラスタの最大類似度なら本人に帰属")
    func multiClusterRescuesGrowth() {
        // 太郎: 乳児期 [1,0,0] と 児童期 [0,1,0]（埋め込みが直交＝離れている）。
        let taro = FacePersonGrouping.PersonModel(personID: 1, clusterReps: [[1, 0, 0], [0, 1, 0]])
        // 別人（花子）: [0,0,1] 方向。
        let hanako = FacePersonGrouping.PersonModel(personID: 2, clusterReps: [[0, 0, 1]])
        // 成長後の太郎の顔（児童期クラスタに近い）。
        let grownTaro = FaceClustering.normalized([0.1, 0.95, 0.1])
        let hit = FacePersonGrouping.nearestPerson(grownTaro, persons: [taro, hanako])
        #expect(hit?.personID == 1)   // 児童期クラスタとの最大類似度で太郎に帰属

        // 融合方式（乳児＋児童を 1 重心に潰す）だと重心は [0.7,0.7,0] 付近で、
        // 児童期の顔との類似度が落ちる＝本人判定が弱くなる（2 階層の優位）。
        let fused = FacePersonGrouping.fusedRep(taro.clusterReps)!
        let fusedSim = FaceClustering.dot(grownTaro, fused)
        let multiSim = hit!.similarity
        #expect(multiSim > fusedSim)   // 最大類似度 > 融合重心との類似度
    }

    @Test("threshold 未満は未知（nil）")
    func belowThresholdIsUnknown() {
        let p = FacePersonGrouping.PersonModel(personID: 1, clusterReps: [[1, 0, 0]])
        #expect(FacePersonGrouping.nearestPerson([0, 1, 0], persons: [p], threshold: 0.5) == nil)
        #expect(FacePersonGrouping.nearestPerson([1, 0, 0], persons: [p], threshold: 0.5)?.personID == 1)
    }

    @Test("単一クラスタなら従来の重心判定に一致（fusedRep も恒等）")
    func singleClusterMatchesCentroid() {
        let reps = [FaceClustering.normalized([3, 4, 0])]
        let fused = FacePersonGrouping.fusedRep(reps)!
        #expect(abs(fused[0] - 0.6) < 1e-4)
        #expect(FacePersonGrouping.fusedRep([]) == nil)
    }
}
