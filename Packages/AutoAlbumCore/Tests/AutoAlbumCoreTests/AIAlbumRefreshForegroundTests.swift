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
/// ⚠️ **規模退行テスト（下段）もこの Suite に入れる**。`BackgroundYield.environmentOverrideForTesting`
/// はプロセス全体で 1 つなのに、swift-testing の Suite は既定で**並列**に走る。別 Suite に分けると、
/// 片方が `.active` を差している間にもう片方の再評価が「前面だから降りる」で 1 件も進まず、
/// 単体では緑・全体では落ちる（実際に踏んだ）。この上書きを使うテストは 1 つの `.serialized`
/// Suite にまとめること。
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
        // ⚠️ 実行マシンの状態（低電力モード等）に左右されないよう、環境を組み立てて差す。
        BackgroundYield.environmentOverrideForTesting = .init(idleSeconds: 999, scenePhase: .active)
        defer { BackgroundYield.environmentOverrideForTesting = nil }

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
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }

        _ = await service.refresh([makeAlbum(id: albumID)])

        #expect(await store.allEnrichedPhotosLiteCallsForTesting >= 1, "台帳を読まずに評価した")
        #expect(service.savedInterpretationForTesting(albumID)?.evaluatedEmbedCount == 1,
                "評価済み件数が進んでいない（次回また同じ再評価が走る）")
    }

    // MARK: - 規模退行（台帳の全件読み出しがアルバム数に比例しないこと・ADR-119）

    /// ⚠️ 直った形: 写真の台帳（`allEnrichedPhotosLite`）とカタログは diagnostics-48 でループの
    /// 外へ出したのに、**タグ台帳（タグ/OCR/人数/美的）だけ取り残されていた**。アルバム 1 本ごとに
    /// 8.6 万行の全件 fetch が 2〜4 回走り、5 本で 10〜20 周ぶんになる。
    /// 「1 回ぶんに見える呼び出しが、実はライブラリ規模 × アルバム数に比例していた」形そのもの。
    /// 検証するのは**時間ではなく回数**（`TagStore.fullLedgerReadsForTesting`）。
    private func makeLedgerStack(albums count: Int) async -> (AIAlbumService, TagStore, [AutoAlbumInfo]) {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([
            EnrichedPhoto(id: "L-a", captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                          latitude: nil, longitude: nil, placeName: nil,
                          clipVector: vector([1, 0, 0]))])
        _ = await store.upsertImportedEmbeddings([
            (refKey: "L-a", vectorHalf: ClipMath.encodeHalf([1, 0, 0]))])
        let tagStore = TagStore(isStoredInMemoryOnly: true)
        _ = await tagStore.recordTags([
            (refKey: "L-a", info: PhotoSenseInfo(tags: ["sea"], ocrText: "beach",
                                                 humanCount: 0, aesthetic: 0.5))])
        let service = AIAlbumService(store: store, tagStore: tagStore,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: FixedEmbedder())
        var infos: [AutoAlbumInfo] = []
        for index in 0..<count {
            let id = "ledger-\(count)-\(index)"
            var saved = SavedInterpretation(
                criteria: "海の写真",
                spec: QuerySpec(clauses: [QueryClause([.content(["sea"])])]),
                semanticText: "photos of the sea",
                scoredPool: [:],
                evaluatedEmbedCount: 0)
            saved.pendingFinalization = false
            service.saveInterpretationForTesting(saved, for: id)
            let info = makeAlbum(id: id)
            await store.upsert(albumInfo: info)
            infos.append(info)
        }
        return (service, tagStore, infos)
    }

    @Test("アルバムが増えても、タグ台帳の全件読み出しは増えない")
    func fullLedgerReadsDoNotScaleWithAlbums() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }

        let (smallService, smallTags, smallAlbums) = await makeLedgerStack(albums: 3)
        let (largeService, largeTags, largeAlbums) = await makeLedgerStack(albums: 12)   // 4 倍

        _ = await smallService.refresh(smallAlbums)
        _ = await largeService.refresh(largeAlbums)

        let small = await smallTags.fullLedgerReadsForTesting
        let large = await largeTags.fullLedgerReadsForTesting

        // ⚠️ fixture が本当に評価まで進んでいるかを先に確かめる（空でも通る assert を書かない）。
        #expect(small > 0, "台帳を一度も読んでいない＝評価まで進んでいない（テストが何も見ていない）")
        #expect(smallService.savedInterpretationForTesting(smallAlbums[0].id)?.evaluatedEmbedCount == 1,
                "評価が進んでいない（fixture が条件を満たしていない）")

        #expect(large <= small,
                """
                アルバム 4 倍（3 → 12 本）で台帳の全件読み出しが \(small) → \(large) 回に増えた。
                台帳はアルバムごとに変わらないので、ループの外で 1 つ（AIAlbumLedgers）にすること。
                """)
    }
}
