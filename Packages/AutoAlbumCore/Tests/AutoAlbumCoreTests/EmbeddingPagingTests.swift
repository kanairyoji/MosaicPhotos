import Foundation
import PerceptionCore
import Testing
@testable import AutoAlbumCore

/// 埋め込みのページ送りが、**走査中の挿入でずれない**こと（ADR-143）。
///
/// ⚠️ 実害: 夜間の埋め込みが走っている最中に AI アルバムを再評価すると、
/// `Fatal error: Duplicate values for key: 'C-/写真/…jpg'` でアプリが落ちた。
/// オフセット送りは、カーソルより前に 1 行入るだけで以降の全ページが 1 つずれ、
/// 同じ写真が 2 回返る。キーセット（refKey > 前回の最後）なら挿入があってもずれない。
@Suite("埋め込みのページ送り", .serialized)
struct EmbeddingPagingTests {

    private func seed(_ store: AutoAlbumStore, keys: [String]) async {
        let photos = keys.map { key in
            EnrichedPhoto(id: key, captureDate: nil, latitude: nil, longitude: nil, placeName: nil)
        }
        await store.upsert(photos)
        var perception: [String: PhotoPerception] = [:]
        for key in keys {
            perception[key] = PhotoPerception(clipVector: ClipMath.encode([1, 0, 0]))
        }
        await store.applyPerception(perception)
    }

    @Test("走査の途中で前に行が入っても、同じ写真を 2 回返さない")
    func keysetPagingSurvivesInserts() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await seed(store, keys: ["C-b", "C-c", "C-d", "C-e"])
        // 前提: 4 件が入っている。
        #expect(await store.enrichmentVectorPage(after: nil, limit: 10).count == 4)

        // 1 ページ目（2 件）。
        let first = await store.enrichmentVectorPage(after: nil, limit: 2)
        #expect(first.map(\.refKey) == ["C-b", "C-c"])

        // ここで**カーソルより前**に 1 件挿入される（夜間の埋め込みが走っている状況）。
        await seed(store, keys: ["C-a"])

        // 2 ページ目: 取りこぼしも重複も無い。
        let second = await store.enrichmentVectorPage(after: first.last?.refKey, limit: 2)
        #expect(second.map(\.refKey) == ["C-d", "C-e"])

        let all = first.map(\.refKey) + second.map(\.refKey)
        #expect(Set(all).count == all.count, "同じ写真が 2 回返っている: \(all)")
    }
}
