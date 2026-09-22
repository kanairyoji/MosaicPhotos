import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// 夜の再クラスタで、平均連結に入れる品質の線（ADR-220）。
@Suite("平均連結に入れる品質の線（ADR-220）", .serialized)
struct InclusionFloorTests {

    private func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("昼のフロア（0.40）未満でも 0.10 以上の顔は平均連結に入り、重心に寄与する")
    func lowQualityFacesJoinAgglomeration() async {
        #expect(FaceTuning.arcFace.agglomeration.inclusionFloor == 0.10)
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 {
            await store.recordScan(refKey: "L-good\(i)", faces: [signal([1, 0.01 * Float(i), 0], quality: 0.9)])
        }
        await store.recordScan(refKey: "L-low", faces: [signal([1, 0.02, 0], quality: 0.20)])
        await store.recordScan(refKey: "L-tiny", faces: [signal([1, 0.03, 0], quality: 0.05)])
        _ = await store.rebuildClusters()

        let person = await store.clusterIDForTesting(faceID: "L-good0#0")
        #expect(person != nil)
        #expect(await store.clusterIDForTesting(faceID: "L-low#0") == person)
        #expect(await store.contributingFaceIDsForTesting(inCluster: person ?? -1).contains("L-low#0"),
                "0.10 以上の顔が平均連結に入っていない（重心に寄与していない）")
        // 0.10 未満は第2パス（所属だけ・重心には寄与しない）。
        #expect(await store.clusterIDForTesting(faceID: "L-tiny#0") == person)
        #expect(!(await store.contributingFaceIDsForTesting(inCluster: person ?? -1).contains("L-tiny#0")))
    }
}
