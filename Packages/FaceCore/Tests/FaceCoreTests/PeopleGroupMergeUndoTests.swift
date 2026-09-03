import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 人物の統合とピープルグループ（ADR-113）の整合。
///
/// ⚠️ グループは **clusterID で人物を指す**。統合すると src の行は消えるので、
/// 参照を付け替えないと `PeopleGroupInfo.resolve` が「現存しないメンバー」として黙って落とす
/// ——ユーザーから見ると**家族グループから 1 人消える**。
/// さらに取り消し（ADR-136）で戻さないと、顔と人物だけ元に戻ってグループは統合先を指し続ける。
@Suite("統合とピープルグループ", .serialized)
struct PeopleGroupMergeUndoTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// A（4 枚）と B（3 枚）が別クラスタで、両方を含む家族グループがあるストア。
    private func makeStore() async -> (store: FaceStore, a: Int, b: Int, group: UUID) {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        let a = map.first { $0.value.contains("L-a0") }?.key ?? -1
        let b = map.first { $0.value.contains("L-b0") }?.key ?? -1
        let group = await store.createPeopleGroup(name: "家族", memberClusterIDs: [a, b])
        return (store, a, b, group)
    }

    private func members(_ store: FaceStore, _ id: UUID) async -> [Int] {
        await store.allPeopleGroupRecords().first { $0.id == id }?.memberClusterIDs ?? []
    }

    @Test("統合するとグループの参照が付け替わる（人が消えない）")
    func mergeRemapsGroupMembership() async {
        let (store, a, b, group) = await makeStore()
        #expect(a >= 0 && b >= 0 && a != b, "fixture: 2 人になっていない")
        #expect(await members(store, group).sorted() == [a, b].sorted(), "fixture: グループが 2 人でない")

        #expect(await store.mergeClusters(from: b, into: a) == nil, "fixture: 統合できていない")

        let after = await members(store, group)
        #expect(after == [a], "統合先 1 人に畳まれていない（消えた ID が残る／重複する）: \(after)")
        // 現存しない ID を残していないこと＝表示で黙って落ちる状態を作らない。
        let live = Set(await store.allClusters().map(\.clusterID))
        #expect(after.allSatisfy { live.contains($0) }, "現存しない人物 ID がグループに残っている")
    }

    @Test("統合を取り消すとグループの構成も戻る")
    func undoRestoresGroupMembership() async {
        let (store, a, b, group) = await makeStore()
        await store.beginUndo(label: "統合", clusterIDs: [a, b])
        #expect(await store.mergeClusters(from: b, into: a) == nil)
        #expect(await members(store, group) == [a], "fixture: 付け替えが起きていない")

        #expect(await store.undoLast() == "統合")
        let after = await members(store, group).sorted()
        #expect(after == [a, b].sorted(),
                "取り消したのにグループが統合後のまま（元の人物がグループから消えたまま）: \(after)")
    }

    /// 統合先が既にメンバーなら、付け替えで**同じ人物を 2 回**入れてはいけない。
    @Test("統合先が既にメンバーなら重複させない")
    func remapDoesNotDuplicate() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        let a = map.first { $0.value.contains("L-a0") }?.key ?? -1
        let b = map.first { $0.value.contains("L-b0") }?.key ?? -1
        // 両方 + もう一度 a（重複しやすい形）。
        let group = await store.createPeopleGroup(name: "家族", memberClusterIDs: [a, b])

        _ = await store.mergeClusters(from: b, into: a)
        let after = await members(store, group)
        #expect(after == [a], "重複または取りこぼしがある: \(after)")
    }

    /// 控えより後に作ったグループまで書き戻すと、**取り消しで新しいグループが壊れる**。
    @Test("控えた後に作られたグループは取り消しで触らない")
    func undoLeavesNewerGroupsAlone() async {
        let (store, a, b, _) = await makeStore()
        await store.beginUndo(label: "統合", clusterIDs: [a, b])
        let newer = await store.createPeopleGroup(name: "あとから", memberClusterIDs: [a])
        _ = await store.mergeClusters(from: b, into: a)
        _ = await store.undoLast()

        #expect(await members(store, newer) == [a], "控えに無いグループまで書き戻している")
    }
}
