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

    /// ⚠️ **大きな人物の統合こそ戻したい**。旧実装は 1 手あたり 5,000 顔で打ち切っており、
    /// 実機ログに `undo skipped — too many faces (5017)` が並んで、
    /// 「1 対 1 の確認で間違えたのに戻すボタンが出ない」状態になっていた（8/31・9/1）。
    /// 上限の理由は行数ではなく `embedding` の materialize だったので、射影して読み、上限を上げた。
    @Test("上限に収まる統合は戻せる（上限を跨ぐと控えない）")
    func largeMergeIsUndoableWithinLimit() async {
        let (store, aID, bID) = await makeStore()
        #expect(aID >= 0 && bID >= 0)

        // 現行の上限（5 万）なら、この規模はもちろん控えられる。
        await store.beginUndo(label: "統合", clusterIDs: [aID, bID])
        #expect(await store.lastUndoLabel() == "統合", "控えが取れていない＝戻すボタンが出ない")
        _ = await store.undoLast()

        // 上限を跨ぐ操作は従来どおり控えない（無制限にはしない）。
        let saved = FaceStore.undoFaceLimit
        FaceStore.undoFaceLimit = 3
        defer { FaceStore.undoFaceLimit = saved }
        await store.beginUndo(label: "大きすぎる統合", clusterIDs: [aID, bID])
        #expect(await store.lastUndoLabel() == nil, "上限を超えたのに控えてしまっている")
    }

    @Test("控えの総量は有界（古い手から捨てる）")
    func undoStackStaysBounded() async {
        let (store, aID, bID) = await makeStore()
        let saved = FaceStore.undoTotalFaceBudget
        FaceStore.undoTotalFaceBudget = 8   // A(4枚)+B(3枚)=7 なので 2 手目で溢れる
        defer { FaceStore.undoTotalFaceBudget = saved }

        await store.beginUndo(label: "1 手目", clusterIDs: [aID, bID])
        await store.beginUndo(label: "2 手目", clusterIDs: [aID, bID])
        #expect(await store.lastUndoLabel() == "2 手目")
        #expect(await store.undoLast() == "2 手目")
        #expect(await store.undoLast() == nil, "総量の上限で古い手が捨てられていない")
    }
}
