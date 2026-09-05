import Foundation
import Testing
@testable import FaceCore

/// AI 解析画面の「残り」は**候補のうち未スキャン**で数える。
/// 記録の総数÷ライブラリ総数だと、削除済みの記録が分子に残り、候補外（スクリーンショット等）が
/// 分母に混ざって、存在しない残作業が表示された（実機: 実際は残 27 枚なのに「残り 1 万枚」）。
@Suite("顔スキャンの残り枚数", .serialized)
struct ScanPendingCountTests {

    @Test("削除済みの記録は分子に入らず、候補外は分母に入らない")
    func pendingCountsOnlyCandidates() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 記録: a, b は候補。z は削除済み写真（候補に無い）。
        _ = await store.recordScans([("L-a", []), ("L-b", []), ("L-z", [])])
        let candidates = ["L-a", "L-b", "L-c", "C-d"]

        let pending = await store.pendingCount(candidateRefKeys: candidates)
        #expect(pending == 2, "未スキャンは c と d の 2 枚（z は数えない）")
        // 旧方式（記録の総数）では 3 になり、分母 4 と合わせて「残り 1」と嘘をつく。
        #expect(await store.scannedCount() == 3)
    }
}
