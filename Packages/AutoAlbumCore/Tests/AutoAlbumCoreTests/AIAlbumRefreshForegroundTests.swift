import Foundation
import MosaicSupport
import Testing
@testable import AutoAlbumCore

/// フル再評価（ドリフト）の**前面判定を、重い前準備の前に置く**こと。
///
/// ⚠️ 実機 diagnostics-67 の形: 前面に戻っているのに台帳 86k 件の読み出し＋カタログ構築
/// （実測 12〜13 秒・footprint 279→490MB）を払い切ってから `aborted for foreground (0/5)` で
/// 捨てていた。**1 件も進まない**ので評価済み件数は変わらず、ドリフト条件は満たされたまま
/// ——つまり毎ティック同じ代金を払い続ける（収束しない輪）。判定は重い段の前ごとに見る。
@Suite("AIAlbum フル再評価の前面判定", .serialized)
@MainActor
struct AIAlbumRefreshForegroundTests {

    private struct FixedEmbedder: TextEmbedder {
        var isAvailable: Bool { true }
        func embed(_ text: String) async -> [Float]? { [1, 0, 0] }
        func prewarm() async {}
    }

    private func vector(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func makeAlbum(id: String) -> AutoAlbumInfo {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return AutoAlbumInfo(id: id, strategyID: AIAlbumStrategy.strategyID, title: "T", placeName: nil, places: [],
                             country: nil, people: [], startDate: now, endDate: now,
                             coverRef: nil, memberRefs: ["L-a"], photoCount: 1,
                             representativeDate: now, latitude: nil, longitude: nil,
                             criteria: "海の写真")
    }

    private func makeStack(albumID: String) async -> (AIAlbumService, AutoAlbumStore) {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([
            EnrichedPhoto(id: "L-a", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                          latitude: nil, longitude: nil, placeName: nil,
                          clipVector: vector([1, 0, 0]))])
        _ = await store.upsertImportedEmbeddings([
            (refKey: "L-a", vectorHalf: ClipMath.encodeHalf([1, 0, 0]))])
        let service = AIAlbumService(store: store, tagStore: nil,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: FixedEmbedder())
        var saved = SavedInterpretation(
            criteria: "海の写真",
            spec: QuerySpec(clauses: [QueryClause([.content(["sea"])])]),
            semanticText: "photos of the sea",
            scoredPool: [:],
            evaluatedEmbedCount: 0)
        saved.pendingFinalization = false
        service.saveInterpretationForTesting(saved, for: albumID)
        // ⚠️ 書き戻しは「アルバムが今も在るか」を見る（canCommit）。台帳に登録しておかないと
        // 評価結果が捨てられ、テストが「読んだのに進まない」形で落ちる。
        await store.upsert(albumInfo: makeAlbum(id: albumID))
        return (service, store)
    }

    @Test("前面に戻っていたら、台帳を読む前に降りる")
    func skipsBeforeTheHeavyLoadWhenForeground() async {
        let albumID = "album-fg"
        let (service, store) = await makeStack(albumID: albumID)
        let wasActive = BackgroundYield.isAppActive
        BackgroundYield.isAppActive = true
        defer { BackgroundYield.isAppActive = wasActive }

        let albums = [makeAlbum(id: albumID)]
        let out = await service.refresh(albums)

        #expect(await store.allEnrichedPhotosLiteCallsForTesting == 0,
                "前面なのに台帳 86k 件を読んだ（代金を払って捨てる形）")
        #expect(out.map(\.id) == albums.map(\.id), "降りるときは現状をそのまま返す")
    }

    /// ⚠️ 「読まない」だけのテストは、評価そのものを壊しても緑になる。非アクティブでは
    /// **ちゃんと読んで評価する**ことも対で確かめる。
    @Test("非アクティブなら通常どおり台帳を読んで評価する")
    func runsWhenInactive() async {
        let albumID = "album-bg"
        let (service, store) = await makeStack(albumID: albumID)
        let wasActive = BackgroundYield.isAppActive
        BackgroundYield.isAppActive = false
        defer { BackgroundYield.isAppActive = wasActive }

        _ = await service.refresh([makeAlbum(id: albumID)])

        #expect(await store.allEnrichedPhotosLiteCallsForTesting >= 1, "台帳を読まずに評価した")
        #expect(service.savedInterpretationForTesting(albumID)?.evaluatedEmbedCount == 1,
                "評価済み件数が進んでいない（次回また同じ再評価が走る）")
    }
}
