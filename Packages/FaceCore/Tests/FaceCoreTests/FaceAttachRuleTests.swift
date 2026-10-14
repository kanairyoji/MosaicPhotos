import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// 顔の所属を書き換える唯一の手順（`detachFace` / `attachFace`）の規則。
///
/// 「まだ無い人物へ入れる 1 枚目は、品質に関わらず種にする／2 枚目以降は品質どおり」。
/// 以前は付け替え（`isNewCluster ||`）と分割（`!seeded ||`）が別々の書き方で持っていた。
/// ⚠️ 両方の向きを縛る——「全部種にする」でも「品質どおり」でも通る形にしない。
@Suite("顔の所属: まだ無い人物の 1 枚目だけ種にする")
struct FaceAttachRuleTests {

    private func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("分割: 低品質 2 枚を新しい人物にすると、種は 1 枚目だけ（重心の件数は 1）")
    func splitSeedsOnlyTheFirstLowQualityFace() async throws {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        for i in 0..<2 {
            await store.recordScan(refKey: "L-low\(i)", faces: [signal([1, 0.02, 0], quality: 0.2)])
        }
        let counts = await store.clusterCountsForTesting()
        let cid = try #require(counts.first?.key)
        let lowIDs = await store.facesForTesting(inCluster: cid).filter { $0.hasPrefix("L-low") }
        // ⚠️ 前提を黙って飛ばさない（低品質顔が同じ人物に入っていなければ、この fixture は何も測らない）。
        try #require(counts.count == 1 && lowIDs.count == 2, "前提: 3 枚が 1 人物に入っている \(counts)")

        let newID = try #require(await store.splitCluster(clusterID: cid, faceIDs: lowIDs))
        let after = await store.clusterCountsForTesting()
        #expect(after[newID] == 1, "種は 1 枚目だけのはず（2 枚目の低品質顔まで重心に入れた）: \(after)")
        #expect(Set(await store.facesForTesting(inCluster: newID)) == Set(lowIDs),
                "2 枚とも新しい人物に属していない")
    }

    @Test("付け替え: 低品質の顔を既にある人物へ移しても、重心には入れない")
    func lowQualityFaceIntoExistingClusterIsMembershipOnly() async throws {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        await store.recordScan(refKey: "L-b", faces: [signal([0, 1, 0], quality: 0.9)])
        await store.recordScan(refKey: "L-low", faces: [signal([1, 0.02, 0], quality: 0.2)])
        let counts = await store.clusterCountsForTesting()
        try #require(counts.count == 2, "前提: 2 人に分かれている \(counts)")
        var lowClusterFound: Int?
        for cid in counts.keys {
            if await store.facesForTesting(inCluster: cid).contains("L-low#0") { lowClusterFound = cid }
        }
        let lowCluster = try #require(lowClusterFound, "前提: 低品質の顔がどこかの人物に入っている")
        let other = try #require(counts.keys.first { $0 != lowCluster })
        let otherBefore = try #require(counts[other])

        await store.reassignFace(faceID: "L-low#0", toClusterID: other)

        let after = await store.clusterCountsForTesting()
        #expect(after[other] == otherBefore, "低品質の顔で既にある人物の重心を動かした")
        #expect(await store.facesForTesting(inCluster: other).contains("L-low#0"), "所属が移っていない")
    }
}
