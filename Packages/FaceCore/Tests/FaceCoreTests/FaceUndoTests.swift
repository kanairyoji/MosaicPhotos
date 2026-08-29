import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 直前の判定を取り消せること（ADR-136）。
///
/// ⚠️ 実フィードバック「確認をしていると、たまに、間違った！と思うことがある」。
/// 取り消しは**逆操作ではなく状態の復元**で実装している——顔の所属・確認印・人物行
/// （重心/名前/代表/束ね）・この操作で記録した学習、の 4 つが戻ることをここで押さえる。
@Suite("直前の判定を取り消す", .serialized)
struct FaceUndoTests {

    private func signal(_ v: [Float], quality: Float = 0.9) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// A（4 枚）と B（3 枚）が別クラスタになっているストア。
    private func makeStore() async -> (FaceStore, Int, Int) {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        let aID = map.first { $0.value.contains("L-a0") }?.key ?? -1
        let bID = map.first { $0.value.contains("L-b0") }?.key ?? -1
        return (store, aID, bID)
    }

    @Test("統合を取り消すと、2 人に戻り、記録した学習も消える")
    func undoMerge() async {
        let (store, aID, bID) = await makeStore()
        #expect(aID >= 0 && bID >= 0 && aID != bID, "fixture: 2 人になっていない")
        #expect(await store.correctionCount() == 0)

        await store.beginUndo(label: "統合", clusterIDs: [aID, bID])
        #expect(await store.mergeClusters(from: bID, into: aID) == nil)
        // 前提: 統合できている（B の写真が A に入り、B の行が消えた）。
        #expect(await store.memberRefKeysByCluster()[aID]?.contains("L-b0") == true)
        #expect(await store.memberRefKeysByCluster()[bID] == nil)
        #expect(await store.correctionCount() == 1, "統合が学習として記録されていない")

        #expect(await store.undoLast() == "統合")

        let after = await store.memberRefKeysByCluster()
        #expect(after[aID]?.contains("L-b0") != true, "統合が戻っていない")
        #expect(after[bID]?.count == 3, "元の人物が復活していない")
        #expect(after[aID]?.count == 4)
        // 統合で付いたアンカー（ADR-134）も、記録した学習も残さない。
        #expect(await store.anchorCount(clusterID: aID) == 0)
        #expect(await store.correctionCount() == 0, "取り消したのに学習が残っている")
    }

    @Test("分離を取り消すと、顔も新しい人物も元に戻る")
    func undoSplit() async {
        let (store, aID, _) = await makeStore()
        let faces = await store.facesForCluster(clusterID: aID)
        let moving = Array(faces.prefix(2).map(\.faceID))
        #expect(moving.count == 2, "fixture: 分離する顔が足りない")
        let peopleBefore = await store.clusterCountsForTesting().count

        await store.beginUndo(label: "分離", clusterIDs: [aID], faceIDs: moving)
        let newID = await store.splitCluster(clusterID: aID, faceIDs: moving)
        #expect(newID != nil)
        #expect(await store.clusterCountsForTesting().count == peopleBefore + 1, "前提: 分離できている")

        #expect(await store.undoLast() == "分離")

        #expect(await store.clusterCountsForTesting().count == peopleBefore, "増えた人物が残っている")
        let members = await store.memberRefKeysByCluster()[aID] ?? []
        #expect(members.count == 4, "分離した顔が戻っていない")
        #expect(await store.correctionCount() == 0, "分離で記録した負例が残っている")
    }

    @Test("戻せるのは控えた手数だけ・再クラスタの後は戻せない")
    func undoDepthAndClear() async {
        let (store, aID, bID) = await makeStore()
        #expect(await store.lastUndoLabel() == nil)
        await store.beginUndo(label: "1 手目", clusterIDs: [aID, bID])
        #expect(await store.lastUndoLabel() == "1 手目")
        await store.clearUndo()
        #expect(await store.lastUndoLabel() == nil)
        #expect(await store.undoLast() == nil, "控えが無いのに何かを戻している")
    }
}
