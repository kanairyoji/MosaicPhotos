import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// **全顔を読む処理は、使い捨てのコンテキストでページ分けして読む**（ADR-227）。
///
/// ⚠️ 何を止めたいか: 「1 枚の写真に同じ人物が 2 回」の修復は**前面のタップごと**に走るのに、
/// 以前は本体のコンテキストで顔を全件 fetch していた（10 万件 × 埋め込み 1KB＝100MB 超が常駐）。
/// 直す顔は普通 0〜数件。**読みはページ・書きは対象だけ**を固定する。
@Suite("全顔の読みはページ分け（ADR-227）", .serialized)
struct FaceReadPagingTests {

    /// 同じ写真に同じ人物の顔を 2 つ作る（違反）＋ 無関係な顔を多数。
    private func makeStore(extraPhotos: Int) async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.apply(tuning: .arcFace)
        // 違反を 1 件作る（`FacePhase1Tests.repairViolations` と同じ手）。
        // 1 枚に同じ埋め込みの顔 2 つ＝同一写真の決まりで別クラスタになるので、
        // 統合ガードを迂回して「1 枚に同じ人物が 2 回」の状態を作る。
        func face(_ v: [Float], _ quality: Float) -> DetectedFaceSignal {
            DetectedFaceSignal(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3),
                               embedding: ClipMath.encodeHalf(v), quality: quality)
        }
        var vector = [Float](repeating: 0, count: 8)
        vector[0] = 1
        await store.recordScan(refKey: "L-dup", faces: [face(vector, 0.9), face(vector, 0.5)])
        for i in 0..<2 { await store.recordScan(refKey: "L-dupp\(i)", faces: [face(vector, 0.9)]) }
        await store.forceMergeForTesting(from: 1, into: 0)
        // 無関係な顔（規模）。人物ごとに直交させる。
        for p in 0..<extraPhotos {
            var v = [Float](repeating: 0, count: 8)
            v[(p % 7) + 1] = 1
            let signal = DetectedFaceSignal(
                boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                embedding: ClipMath.encodeHalf(v), quality: 0.9)
            await store.recordScan(refKey: "L-p\(p)", faces: [signal])
        }
        return store
    }

    @Test("修復は違反を直しつつ、全顔を本体のコンテキストへ読み込まない")
    func repairReadsFacesByPage() async {
        let store = await makeStore(extraPhotos: 40)
        let before = await store.fetchCountForTesting

        let repaired = await store.repairSamePhotoViolations()

        // ⚠️ fixture が本当に違反になっていることを確かめる（空でも通る assert を書かない）。
        #expect(repaired >= 1, "同一写真の違反が作れていない（テストが何も見ていない）")
        // 読みはページ経路を通っていること（＝本体のコンテキストに全顔を登録していない）。
        #expect(await store.pagedFaceRowsForTesting > 0, "ページ読みを通っていない")
        // 本体のコンテキストの数える fetch は、規模に比例して増えない。
        let counted = await store.fetchCountForTesting - before
        #expect(counted <= 8, "本体のコンテキストで \(counted) 回引いている（規模に比例しないこと）")
    }

    /// ⚠️ 規模を 4 倍にしても、**本体のコンテキストで引く回数**は増えないこと（ADR-119 の形）。
    @Test("顔が 4 倍になっても、本体のコンテキストで引く回数は増えない")
    func liveFetchesDoNotScale() async {
        let small = await makeStore(extraPhotos: 40)
        let large = await makeStore(extraPhotos: 160)

        let smallBefore = await small.fetchCountForTesting
        _ = await small.repairSamePhotoViolations()
        let smallCount = await small.fetchCountForTesting - smallBefore

        let largeBefore = await large.fetchCountForTesting
        _ = await large.repairSamePhotoViolations()
        let largeCount = await large.fetchCountForTesting - largeBefore

        let smallRows = await small.pagedFaceRowsForTesting
        let largeRows = await large.pagedFaceRowsForTesting
        #expect(largeRows > smallRows, "fixture の規模が増えていない（テストが何も見ていない）")
        #expect(largeCount <= smallCount, """
            顔 4 倍で本体のコンテキストの fetch が \(smallCount) → \(largeCount) 回に増えた。
            """)
    }
}
