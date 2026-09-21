import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 散らばりの記録を、**永続層を通して**確かめる（ADR-210）。
/// 散らばりは事後監査の順番と判定の内訳に使う（重心の凍結は撤回・ADR-216）。
@Suite("散らばりの記録（配線）", .serialized)
struct ClusterSpreadIntegrationTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func signal(_ v: [Float], quality: Float, box: CGRect,
                        at offset: TimeInterval) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: box, embedding: ClipMath.encodeHalf(v), quality: quality,
                           captureDate: base.addingTimeInterval(offset))
    }

    private func box(_ x: Double) -> CGRect {
        CGRect(x: x, y: 0.4, width: 0.2, height: 0.2)
    }

    // MARK: - 散らばりの記録（ADR-210）

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

    @Test("散らばりを記録しても、人物は普通に育つ")
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
