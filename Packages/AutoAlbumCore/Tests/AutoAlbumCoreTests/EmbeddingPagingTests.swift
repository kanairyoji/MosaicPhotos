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

/// ⚠️ 並びと `>` の順序が食い違うと、**ページの継ぎ目で行が飛ぶ／二重に返る**。
/// `SortDescriptor(\.refKey)` の既定は数字を意識した順（"…-5" < "…-49"）で並べる一方、
/// `#Predicate` の `>` は単純な文字列比較。実データの refKey（`L-<UUID>`・`C-/写真/2024-05-03/…`）
/// は数字を含むので、この食い違いが起き得る。FaceCore の同型コードで**160 件中 100 件しか
/// 読めない**ことが規模テストで発覚した（ADR-178）。
@Suite("ページ送りの順序（数字入りのキー）", .serialized)
struct EmbeddingPagingOrderTests {

    private func seed(_ store: AutoAlbumStore, keys: [String]) async {
        let photos = keys.map { key in
            EnrichedPhoto(id: key, captureDate: nil, latitude: nil, longitude: nil, placeName: nil)
        }
        await store.upsert(photos)
        var perception: [String: PhotoPerception] = [:]
        for key in keys { perception[key] = PhotoPerception(clipVector: ClipMath.encode([1, 0, 0])) }
        await store.applyPerception(perception)
    }

    /// 数字入りのキーを 160 件。ページ 50 で全件が**ちょうど 1 回ずつ**返ること。
    @Test("数字入りのキーでも、全件をちょうど 1 回ずつ返す（埋め込み）")
    func vectorPagingIsCompleteWithNumericKeys() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let keys = (0..<160).map { "L-photo-\($0)" }
        await seed(store, keys: keys)
        #expect(await store.embeddedCount() == 160, "fixture: 160 件入っていない")

        var seen: [String] = []
        var cursor: String?
        while true {
            let page = await store.enrichmentVectorPage(after: cursor, limit: 50)
            if page.isEmpty { break }
            seen += page.map(\.refKey)
            cursor = page.last?.refKey
            if page.count < 50 { break }
        }
        #expect(seen.count == 160, "ページの継ぎ目で取りこぼしている: \(seen.count)/160")
        #expect(Set(seen).count == 160, "同じ写真が 2 回返っている")
    }

    @Test("数字入りのキーでも、全件をちょうど 1 回ずつ返す（メタ一覧）")
    func liteListingIsCompleteWithNumericKeys() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        // 本番のページは 5,000。継ぎ目の挙動はページ幅に依らないので、小さな幅で複数ページを跨がせる
        //（5,200 件を入れると SwiftData の挿入だけで 2 分かかる）。
        let keys = (0..<160).map { "C-/写真/2024-05-03/dsc\($0).jpg" }
        await seed(store, keys: keys)
        let all = await store.allEnrichedPhotosLite(pageSize: 50)
        #expect(all.count == 160, "ページの継ぎ目で取りこぼしている: \(all.count)/160")
        #expect(Set(all.map(\.id)).count == 160, "同じ写真が 2 回返っている")
    }
}
