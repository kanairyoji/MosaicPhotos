import Foundation
import PerceptionCore
import Testing
@testable import AutoAlbumCore

/// モデル更新の移行（ADR-186）: 旧モデルの埋め込みは**消さずに**残し、新しい写真から順に上書きする。
@Suite("埋め込みのモデル移行", .serialized)
struct EmbeddingModelMigrationTests {

    private func half(_ v: [Float]) -> Data { ClipMath.encodeHalf(v) }

    @Test("旧モデルの行だけが移行対象になり、新しい写真から順に返る")
    func staleRowsNewestFirst() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        await store.upsert([
            EnrichedPhoto(id: "L-old-2", captureDate: t.addingTimeInterval(200), latitude: nil, longitude: nil, placeName: nil),
            EnrichedPhoto(id: "L-old-1", captureDate: t.addingTimeInterval(100), latitude: nil, longitude: nil, placeName: nil),
            EnrichedPhoto(id: "L-new",   captureDate: t.addingTimeInterval(300), latitude: nil, longitude: nil, placeName: nil),
        ])
        await store.insertEmbeddingForTesting(refKey: "L-old-2", vector: half([1, 0]), modelID: "old-model")
        await store.insertEmbeddingForTesting(refKey: "L-old-1", vector: half([1, 0]), modelID: "old-model")
        await store.insertEmbeddingForTesting(refKey: "L-new", vector: half([0, 1]), modelID: ModelGeneration.clip)

        #expect(await store.staleEmbeddingCount() == 2)
        #expect(await store.staleEmbeddingRefKeys(limit: 10) == ["L-old-2", "L-old-1"], "新しい写真から")
        #expect(await store.staleEmbeddingRefKeys(limit: 1) == ["L-old-2"])
    }

    @Test("列を足す前の行（modelID = nil）は現行とみなし、移行対象にも検索除外にもならない")
    func legacyRowsAreCurrent() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([EnrichedPhoto(id: "L-a", captureDate: nil, latitude: nil, longitude: nil, placeName: nil)])
        await store.insertEmbeddingForTesting(refKey: "L-a", vector: half([1, 0]), modelID: nil)
        #expect(await store.staleEmbeddingCount() == 0)
        #expect(ModelGeneration.isCurrentClip(nil))
        #expect(await store.enrichmentVectorPage(after: nil, limit: 10).map(\.refKey) == ["L-a"])
    }

    @Test("上書きすると現行の空間になり、旧空間の行は検索から外れる")
    func overwriteMigratesAndSearchSkipsStale() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([EnrichedPhoto(id: "L-a", captureDate: nil, latitude: nil, longitude: nil, placeName: nil),
                            EnrichedPhoto(id: "L-b", captureDate: nil, latitude: nil, longitude: nil, placeName: nil)])
        await store.insertEmbeddingForTesting(refKey: "L-a", vector: half([1, 0]), modelID: "old-model")
        await store.insertEmbeddingForTesting(refKey: "L-b", vector: half([1, 0]), modelID: "old-model")
        // 検索ページ: 旧空間は混ぜない（テキストタワーが残っていないので当てられない）。
        #expect(await store.enrichmentVectorPage(after: nil, limit: 10).isEmpty)
        // a を新モデルで上書き（applyPerception）。
        await store.applyPerception(["L-a": PhotoPerception(clipVector: ClipMath.encode([0, 1]))])
        #expect(await store.staleEmbeddingRefKeys(limit: 10) == ["L-b"])
        #expect(await store.enrichmentVectorPage(after: nil, limit: 10).map(\.refKey) == ["L-a"])
    }
}
