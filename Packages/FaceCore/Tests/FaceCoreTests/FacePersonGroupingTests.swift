import Foundation
import Testing
@testable import FaceCore

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

    @Test("personReps: 子供は撮影日で時期グループに分割・大人は 1 融合グループ")
    func personRepsChildVsAdult() {
        func d(_ y: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(y) * 31_536_000) }
        // 3 時期（乳児 [1,0,0] / 幼児 [0,1,0] / 児童 [0,0,1]）各 2 枚。
        let faces: [(embedding: [Float], date: Date?)] = [
            ([1, 0, 0], d(1)), ([0.9, 0.1, 0], d(1)),
            ([0, 1, 0], d(4)), ([0.1, 0.9, 0], d(4)),
            ([0, 0, 1], d(8)), ([0, 0.1, 0.9], d(8)),
        ]
        // 子供: 撮影日で 3 グループ→各時期の重心。
        let childReps = FacePersonGrouping.personReps(faces: faces, isChild: true, maxGroups: 3)
        #expect(childReps.count == 3)
        // 各グループが対応する時期方向を向く（乳児群は x 方向が支配的）。
        #expect(childReps[0][0] > childReps[0][1] && childReps[0][0] > childReps[0][2])
        #expect(childReps[2][2] > childReps[2][0] && childReps[2][2] > childReps[2][1])
        // 大人: 何枚あっても 1 融合グループ。
        let adultReps = FacePersonGrouping.personReps(faces: faces, isChild: false)
        #expect(adultReps.count == 1)
    }

    @Test("personReps: 顔が少ない/撮影日 nil/maxGroups=1 でも安全に 1 グループ")
    func personRepsEdges() {
        let one: [(embedding: [Float], date: Date?)] = [([1, 0, 0], nil)]
        #expect(FacePersonGrouping.personReps(faces: one, isChild: true).count == 1)
        let noDate: [(embedding: [Float], date: Date?)] = [([1, 0, 0], nil), ([0, 1, 0], nil), ([0, 0, 1], nil)]
        #expect(FacePersonGrouping.personReps(faces: noDate, isChild: true, maxGroups: 3).count == 3)  // nil でも等分
        #expect(FacePersonGrouping.personReps(faces: noDate, isChild: true, maxGroups: 1).count == 1)
        #expect(FacePersonGrouping.personReps(faces: [], isChild: true).isEmpty)
    }

    @Test("子供の時期グループ帰属: 成長後の顔が対応時期グループで本人に")
    func childTimeGroupIdentifies() {
        func d(_ y: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(y) * 31_536_000) }
        let taroFaces: [(embedding: [Float], date: Date?)] = [
            ([1, 0, 0], d(1)), ([0, 1, 0], d(5)), ([0, 0, 1], d(10)),
        ]
        let taro = FacePersonGrouping.PersonModel(
            personID: 1, clusterReps: FacePersonGrouping.personReps(faces: taroFaces, isChild: true, maxGroups: 3))
        let hanako = FacePersonGrouping.PersonModel(personID: 2, clusterReps: [[0.7, 0.7, 0]])
        // 児童期の太郎（[0,0,1] 方向）は融合重心では外れるが、時期グループなら本人に帰属。
        let grown = FaceClustering.normalized([0.1, 0.1, 0.95])
        #expect(FacePersonGrouping.nearestPerson(grown, persons: [taro, hanako])?.personID == 1)
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
