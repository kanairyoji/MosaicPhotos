import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 重心の凍結を、**永続層を通して**確かめる（ADR-210）。
/// 純ロジック側の判断は `FaceClusterHealthTests` で固定済みなので、ここは配線を見る。
@Suite("重心の凍結（配線）", .serialized)
struct CentroidFreezeIntegrationTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func signal(_ v: [Float], quality: Float, box: CGRect,
                        at offset: TimeInterval) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: box, embedding: ClipMath.encodeHalf(v), quality: quality,
                           captureDate: base.addingTimeInterval(offset))
    }

    private func box(_ x: Double) -> CGRect {
        CGRect(x: x, y: 0.4, width: 0.2, height: 0.2)
    }

    // MARK: - 重心の凍結（ADR-210）

    @Test("再クラスタは各人物の散らばりを測って記録する")
    func rebuildRecordsSpread() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<8 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.02, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        _ = await store.rebuildClusters()
        let person = await store.clusterIDForTesting(faceID: "L-a0#0") ?? -1
        let spread = (await store.spreadsForTesting()[person]) ?? nil
        #expect(spread != nil)
        #expect(spread.map { $0 < 0.1 } == true)   // 同じ人なので散らばりは小さい
    }

    /// 散らばりすぎた人物は、次のスキャンで**所属だけ**受け取る（重心が動かない）。
    @Test("散らばった人物の重心は、次のスキャンで動かない")
    func driftedClusterStopsGrowing() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<12 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        let before = await store.clusterCountsForTesting()[0]
        // 「過半のメンバーが、今のしきい値ではもう入らない」状態を直に作る。
        await store.setClusterSpreadForTesting(clusterID: 0, spread: 0.95)

        await store.recordScan(refKey: "L-new",
                               faces: [signal([1, 0.01, 0], quality: 0.9, box: box(0.1),
                                              at: 999_999)])
        #expect(await store.facesForTesting(inCluster: 0).contains("L-new#0"))
        #expect(await store.clusterCountsForTesting()[0] == before)   // 重心は据え置き
        #expect(await store.contributingFaceIDsForTesting(inCluster: 0).contains("L-new#0") == false)
    }

    @Test("散らばりが小さい人物は普通に育つ（凍結しない）")
    func healthyClusterKeepsGrowing() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<12 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        _ = await store.rebuildClusters()
        let person = await store.clusterIDForTesting(faceID: "L-a0#0") ?? -1
        let before = await store.clusterCountsForTesting()[person] ?? 0
        await store.recordScan(refKey: "L-new",
                               faces: [signal([1, 0.01, 0], quality: 0.9, box: box(0.1),
                                              at: 999_999)])
        #expect(await store.clusterCountsForTesting()[person] == before + 1)
    }
}
