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

    /// 回帰: **移行中でもページ走査が途中で止まらない**（レビュー 16 周目）。
    ///
    /// ⚠️ `fetchLimit` は絞り込みの**前**に効くので、旧モデルの行が混ざるページは短くなる。
    /// 呼び出し側は「ページが上限より短い＝表の終わり」で打ち切るため、絞り込みだけで
    /// 走査が終わってしまう。移行は**新しい写真から**進むので refKey 順では現行行が散らばり、
    /// 1 ページ目でほぼ必ず短くなる——**AI アルバムの意味検索が 1 ページぶんしか効かない**。
    @Test("旧モデルの行が混ざっても、現行の行を最後まで読み切る")
    func pagingDoesNotStopAtFilteredPages() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        // 現行と旧モデルを交互に。refKey 昇順で並ぶよう 2 桁で作る。
        var photos: [EnrichedPhoto] = []
        for i in 0..<20 {
            photos.append(EnrichedPhoto(id: String(format: "L-%02d", i), captureDate: nil,
                                        latitude: nil, longitude: nil, placeName: nil))
        }
        await store.upsert(photos)
        for i in 0..<20 {
            await store.insertEmbeddingForTesting(
                refKey: String(format: "L-%02d", i), vector: half([1, 0]),
                modelID: i.isMultiple(of: 2) ? ModelGeneration.clip : "old-model")
        }

        // 上限 4 で読み進める。現行は 10 行あるので、全部読めるはず。
        var cursor: String?
        var seen: [String] = []
        for _ in 0..<20 {
            let page = await store.enrichmentVectorPage(after: cursor, limit: 4)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.refKey))
            cursor = page.last?.refKey
            if page.count < 4 { break }
        }
        #expect(seen.count == 10,
                "現行の行を \(seen.count)/10 しか読めていない（意味検索から写真が黙って消える）")
        #expect(seen == (0..<20).filter { $0.isMultiple(of: 2) }.map { String(format: "L-%02d", $0) })
    }

    /// 回帰: **増分評価も旧空間のベクトルを混ぜない**（ADR-186・レビュー 16 周目）。
    /// ページ走査の側は現行だけを返すのに、増分の入口には絞り込みが無く、
    /// 旧空間のベクトルを新しいテキストタワーと突き合わせて永続プールへ混ぜていた。
    @Test("増分評価の取り出しも、旧モデルの行を返さない")
    func incrementalVectorsSkipStaleRows() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([
            EnrichedPhoto(id: "L-cur", captureDate: nil, latitude: nil, longitude: nil, placeName: nil),
            EnrichedPhoto(id: "L-old", captureDate: nil, latitude: nil, longitude: nil, placeName: nil),
        ])
        await store.insertEmbeddingForTesting(refKey: "L-cur", vector: half([1, 0]),
                                              modelID: ModelGeneration.clip)
        await store.insertEmbeddingForTesting(refKey: "L-old", vector: half([0, 1]),
                                              modelID: "old-model")
        let got = await store.vectors(forRefKeys: ["L-cur", "L-old"])
        #expect(got.keys.sorted() == ["L-cur"],
                "旧空間のベクトルを増分評価へ渡している（採点が意味を失う）")
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
