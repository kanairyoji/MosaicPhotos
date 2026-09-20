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

    @Test("理由の分かっている欠け（候補から外したバックアップコピー）は割合に関係なく消す")
    func knownGoneBypassesTheFraction() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans((0..<20).map { ("C-copy\($0)", [signal(unit($0 % 8))]) }
                                    + [("L-a", [signal(unit(0))])])
        let copies = Set((0..<20).map { "C-copy\($0)" })
        let result = await store.pruneMissingPhotos(existingRefKeys: ["L-a"], knownGone: copies)
        #expect(result?.photos == 20, "95% の欠けでも理由があれば消す")
        #expect(await store.scannedCount() == 1)
    }
}

// MARK: - クラスタ ID の再利用禁止・表明した人物の保全（ADR-187）

@Suite("クラスタ ID と人物の保全", .serialized)
struct ClusterIdentityTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }
    private func unit(_ i: Int, dims: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: dims); v[i] = 1; return v
    }

    @Test("最大 ID の人物が消えても、次の人物は同じ ID を受け取らない")
    func clusterIDsAreNeverReused() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans([("L-a", [signal(unit(0))]), ("L-b", [signal(unit(1))])])
        let ids = await store.allClusters().map(\.clusterID).sorted()
        #expect(ids.count == 2, "fixture: 2 人物になっていない")
        let maxID = ids.last!
        // 最大 ID の人物が消える（写真の削除・掃除で行ごと無くなった状況）。
        await store.deleteClusterRowForTesting(maxID)
        _ = await store.repairOrphanFaces()
        #expect(await store.allClusters().map(\.clusterID).contains(maxID) == false, "fixture: 消えていない")
        // 新しい人物を作る → 消えた ID より大きい ID になること。
        _ = await store.recordScans([("L-c", [signal(unit(3))])])
        let newIDs = await store.allClusters().map(\.clusterID)
        #expect(!newIDs.contains(maxID) && newIDs.max()! > maxID,
                "消えた ID が再利用された（参照側が別人を指す）")
    }

    /// 回帰: ADR-187 の規則は**手での編集の経路にも**効くこと。
    /// `persist` と `rebuildClusters` は高水位から採るよう直されたが、
    /// 付け替え・分割が使う `nextClusterID()` だけ「いまある最大＋1」のまま残っていた
    /// （レビュー指摘）。家族のピープルグループや共有セットは ID で人を指すので、
    /// 再利用されると**別人の写真が家族の共有フォルダへ流れ込む**。
    @Test("最大 ID の人物が消えた後、手で直しても同じ ID を配らない")
    func manualEditDoesNotReuseRetiredClusterID() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans([("L-a", [signal(unit(0))]), ("L-b", [signal(unit(1))]),
                                     ("L-c", [signal(unit(2))])])
        let ids = await store.allClusters().map(\.clusterID).sorted()
        #expect(ids.count == 3, "fixture: 3 人物になっていない")
        let maxID = ids.last!

        await store.deleteClusterRowForTesting(maxID)
        _ = await store.repairOrphanFaces()
        #expect(await store.allClusters().map(\.clusterID).contains(maxID) == false,
                "fixture: 消えていない")

        // 手での編集（「この人ではない」＝新しい人物へ付け替え）。
        let issued = await store.nextClusterIDForTesting()
        #expect(issued > maxID, "消えた ID を手での編集が配り直した: \(issued) <= \(maxID)")
    }

    @Test("名前の付いた人物は最後の顔が外れても行が残る（名前を失わない）")
    func namedClusterSurvivesLosingLastFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans([("L-a", [signal(unit(0))])])
        let id = await store.allClusters().first!.clusterID
        await store.rename(clusterID: id, name: "太郎")
        _ = await store.removePhoto(refKey: "L-a", from: id)
        let c = await store.allClusters().first { $0.clusterID == id }
        #expect(c?.name == "太郎", "名前付きの行が消えた")
        #expect(c?.count == 0)
    }

    @Test("消えたクラスタを指す孤児の顔は未割当に戻る")
    func orphanFacesAreRepaired() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await store.recordScans([("L-a", [signal(unit(0))])])
        let id = await store.allClusters().first!.clusterID
        await store.deleteClusterRowForTesting(id)   // 行だけ消えた（旧実装の掃除・付け替え）
        #expect(await store.repairOrphanFaces() == 1)
        #expect(await store.repairOrphanFaces() == 0)
    }
}
