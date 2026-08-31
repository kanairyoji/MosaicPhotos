import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 実機の再現手順（8/31）: 「別の人かもしれない写真」→ さらに表示 → その顔を「この人ではない」で
/// 新しい人物へ分離 → クラッシュ（CRASH SIGTRAP・直前の操作 people.reassignFace → new）。
@Suite("外れ顔を新しい人物へ分離する", .serialized)
struct ReassignOutlierTests {

    private func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("さらに表示 → 分離 → 一覧再構築が落ちない")
    func reassignOutlierToNewPerson() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 大きめの人物（品質もばらつかせる。低品質＝membership だけの顔を混ぜる）。
        for i in 0..<40 {
            let q: Float = (i % 5 == 0) ? 0.42 : 0.9
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0.02], quality: q)])
        }
        // 少し離れた顔（外れ候補になりやすい）。
        for i in 0..<6 {
            await store.recordScan(refKey: "L-c\(i)",
                                   faces: [signal([0.82, 0.55, Float(i) * 0.01], quality: 0.5)])
        }
        let map = await store.memberRefKeysByCluster()
        let focusID = map.max { $0.value.count < $1.value.count }?.key ?? -1
        #expect(focusID >= 0, "fixture: クラスタができていない")

        // 「さらに表示」した状態（上限を広げて読む）。
        var report = await store.decisionReport(clusterID: focusID, limit: 48, outlierLimit: 96)
        #expect(report != nil, "fixture: レポートが作れていない")
        #expect(report?.outliers.isEmpty == false, "fixture: 外れ候補が 1 件も無い")
        for row in report?.neighbors ?? [] {
            #expect(row.similarity.isFinite, "近傍の類似度が有限でない（%表示で trap する）")
        }

        // 外れ顔を「この人ではない」＝新しい人物へ分離する（実機の操作）。
        for face in (report?.outliers ?? []).prefix(3) {
            await store.beginUndo(label: "分離", clusterIDs: [], faceIDs: [face.faceID])
            await store.reassignFace(faceID: face.faceID, toClusterID: nil)
            // 直後に画面が読み直すもの（人物一覧・レポート・確認候補）を全部通す。
            _ = await store.peopleClusters(minFaces: 1)
            report = await store.decisionReport(clusterID: focusID, limit: 48, outlierLimit: 96)
            _ = await store.reviewItems(minFaces: 3, limit: 5)
            _ = await store.batchReviewItem(minFaces: 3)
            for row in report?.outliers ?? [] {
                #expect(row.similarity.isFinite, "外れ顔の類似度が有限でない")
            }
        }
    }

    /// ⚠️ **壊れた埋め込み（NaN）を表示側へ渡さない**。`%` 表示は `Int(_:)` 変換なので、
    /// NaN をそのまま渡すと**画面に出そうとしただけで trap する**（Swift の仕様）。
    /// 「別の人かもしれない写真」は類似度の低い順なので、壊れた値ほど目に触れる位置に来る。
    @Test("壊れた埋め込みは間違い候補に出さない")
    func brokenEmbeddingIsExcluded() async {
        // 前提: 壊れた埋め込みは **NaN のまま復元される**（復元側は弾かない）。
        // これが成り立たないと、このテストは「何も起きていないのに通る」ことになる。
        #expect(ClipMath.decodeHalf(ClipMath.encodeHalf([Float.nan, 0, 0]))?.first?.isNaN == true,
                "前提: NaN が復元時に落ちてしまっている")

        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0.02], quality: 0.9)])
        }
        let map = await store.memberRefKeysByCluster()
        let focusID = map.max { $0.value.count < $1.value.count }?.key ?? -1
        #expect(focusID >= 0, "fixture: クラスタができていない")

        // NaN 入りの顔を同じ人物へ差し込む（実機で壊れた行が紛れ込んだ状況）。
        await store.recordScan(refKey: "L-nan",
                               faces: [signal([Float.nan, Float.nan, Float.nan], quality: 0.9)])
        let members = await store.memberRefKeysByCluster()
        let nanCluster = members.first { $0.value.contains("L-nan") }?.key
        #expect(nanCluster != nil, "fixture: NaN の顔が記録されていない")
        if let nanCluster, nanCluster != focusID {
            let faces = await store.facesForCluster(clusterID: nanCluster)
            for f in faces { await store.reassignFace(faceID: f.faceID, toClusterID: focusID) }
        }
        #expect(await store.memberRefKeysByCluster()[focusID]?.contains("L-nan") == true,
                "fixture: NaN の顔が調査対象の人物に入っていない")

        let report = await store.decisionReport(clusterID: focusID, limit: 24, outlierLimit: 96)
        #expect(report != nil)
        for face in report?.outliers ?? [] {
            #expect(face.similarity.isFinite, "壊れた類似度が表示側へ漏れている（% 表示で落ちる）")
        }
        #expect(report?.outliers.contains { $0.refKey == "L-nan" } == false,
                "NaN の顔が候補に出ている")
    }
}
