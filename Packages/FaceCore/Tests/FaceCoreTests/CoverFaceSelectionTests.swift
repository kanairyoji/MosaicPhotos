import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 代表顔の選び方（ADR-214）。
///
/// ⚠️ 代表顔は見た目だけの話ではない——命名・代表選択で**アンカー**になり、再クラスタで
/// 動かない錨になる（ADR-130/132）。混ざり込んだ別人の「よく写った顔」が代表になると、
/// その別人がこの人物の同一性そのものになる（ADR-130 の実害の増幅経路）。
@Suite("代表顔の選択（ADR-214）", .serialized)
struct CoverFaceSelectionTests {

    private func signal(_ v: [Float], quality: Float, smile: Bool = false)
        -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4),
                           embedding: ClipMath.encodeHalf(v), quality: quality, hasSmile: smile)
    }

    /// 本人 6 枚（やや控えめな品質）＋ 混入した別人 1 枚（高品質・笑顔）。
    private func makeStoreWithAnIntruder() async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-self\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.6)])
        }
        // 重心から遠い（cos ≈ 0.20）が、品質も笑顔も申し分ない顔を無理やり同じ人物へ入れる。
        await store.recordScan(refKey: "L-intruder",
                               faces: [signal([0, 1, 0], quality: 1.0, smile: true)])
        await store.reassignFace(faceID: "L-intruder#0", toClusterID: 0)
        return store
    }

    @Test("重心から遠い顔は、どれだけ綺麗でも代表にしない")
    func farFaceIsNotChosenAsCover() async {
        let store = await makeStoreWithAnIntruder()
        let cover = await store.coverFaceIDForTesting(inCluster: 0)
        #expect(cover != nil)
        #expect(cover != "L-intruder#0")   // 見た目だけなら必ずこれが選ばれる
        #expect(cover?.hasPrefix("L-self") == true)
    }

    /// ⚠️ 絞って 0 人になると代表が消え、人物が一覧から落ちる。全員が遠いときは絞らない。
    @Test("全員が重心から遠いときは絞らない（代表が消えない）")
    func neverReturnsNilJustBecauseEveryoneIsFar() {
        let faces: [DetectedFace] = []
        #expect(FaceStore.bestCoverFace(faces, centroid: [1, 0, 0], minSimilarity: 0.5) == nil)
    }

    /// 従来の規則（品質＋笑顔＋大きさ、同点は faceID の小さい方・ADR-139）は変えていない。
    @Test("重心を渡さなければ従来どおり見た目で選ぶ・同点は決定的")
    func withoutCentroidBehaviourIsUnchanged() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-b", faces: [signal([1, 0, 0], quality: 0.8)])
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0.01, 0], quality: 0.8)])
        let members = await store.facesForTesting(inCluster: 0).sorted()
        #expect(members.count == 2)
        // 同点 → faceID の小さい方（"L-a#0"）。
        #expect(await store.coverFaceIDForTesting(inCluster: 0) == "L-a#0")
    }
}
