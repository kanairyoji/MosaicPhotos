import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// 写真が無くなった顔の掃除（実フィードバック: 「似ている人」にサムネの出ない顔が並び、開けない）。
@Suite("無くなった写真の顔の掃除", .serialized)
struct PruneMissingPhotosTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    private func unit(_ i: Int, dims: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dims); v[i] = 1; return v
    }

    @Test("無い写真の顔と走査記録が消え、空になった人物も消える")
    func prunesFacesAndEmptyClusters() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 人物 A: 写真 a0…a39（残る）。人物 B: 写真 b1 だけ（写真ごと消える）。顔なし写真 1 枚。
        // ⚠️ 欠けは走査記録の 5% 以内でないと掃除されない（安全弁）ので、A を 40 枚にする。
        let aPhotos = (0..<40).map { ("L-a\($0)", [signal(unit(0))]) }
        _ = await store.recordScans(aPhotos + [("L-b1", [signal(unit(3))]), ("L-none", [])])
        #expect(await store.scannedCount() == 42)
        let clustersBefore = await store.allClusters().count
        #expect(clustersBefore == 2, "fixture: 2 人物になっていない")

        let existing = Set(aPhotos.map(\.0) + ["L-none"])
        let result = await store.pruneMissingPhotos(existingRefKeys: existing)
        #expect(result?.faces == 1)
        #expect(result?.photos == 1)
        #expect(result?.clusters == 1)
        #expect(await store.scannedCount() == 41)
        #expect(await store.allClusters().count == 1)
        #expect(await store.faceCount() == 40)
    }

    @Test("欠けが多すぎる（候補が揃っていない）ときは何も消さない")
    func refusesWhenCandidatesLookIncomplete() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans((0..<20).map { ("L-\($0)", [signal(unit($0 % 8))]) })
        // 候補に 1 枚しか無い＝ 95% 欠け → 拒否。
        let result = await store.pruneMissingPhotos(existingRefKeys: ["L-0"])
        #expect(result == nil)
        #expect(await store.scannedCount() == 20, "実在するかもしれない顔を消した")
    }
}
