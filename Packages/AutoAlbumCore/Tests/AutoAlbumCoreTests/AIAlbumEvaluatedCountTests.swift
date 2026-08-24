import Foundation
import Testing
@testable import AutoAlbumCore

/// ⚠️ 増分再評価は「評価済み枚数」を進めながら差分を採点する。以前はクエリ埋め込みの取得**前**に
/// 枚数を進めていたため、モデルのロード失敗やキャンセルで埋め込みが取れなかった回の写真が
/// **採点されていないのに評価済み**になり、ドリフト検知も差分ゼロと判断して二度と再評価
/// されなかった（レビュー指摘）。採点できたときだけ進めること。
@Suite("AIAlbum incremental — evaluatedEmbedCount")
@MainActor
struct AIAlbumEvaluatedCountTests {

    /// 埋め込みを返さない TextEmbedder（モデル未ロード・一時失敗を模す）。
    private struct FailingEmbedder: TextEmbedder {
        var isAvailable: Bool { true }
        func embed(_ text: String) async -> [Float]? { nil }
        func prewarm() async {}
    }

    /// 常に同じ方向のベクトルを返す TextEmbedder（採点が成立するケース）。
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
        return AutoAlbumInfo(id: id, strategyID: "ai", title: "T", placeName: nil, places: [],
                             country: nil, people: [], startDate: now, endDate: now,
                             coverRef: nil, memberRefs: ["L-existing"], photoCount: 1,
                             representativeDate: now, latitude: nil, longitude: nil,
                             criteria: "海の写真")
    }

    /// 解釈を保存し、新規 1 枚を投入した状態のサービスを作る。
    private func makeService(embedder: TextEmbedder, albumID: String) async -> AIAlbumService {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        await store.upsert([
            EnrichedPhoto(id: "L-new", captureDate: Date(timeIntervalSince1970: 1_700_000_100),
                          latitude: nil, longitude: nil, placeName: nil,
                          clipVector: vector([1, 0, 0]))
        ])
        let service = AIAlbumService(store: store, tagStore: nil,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: embedder)
        var saved = SavedInterpretation(
            criteria: "海の写真",
            spec: QuerySpec(clauses: [QueryClause([.content(["sea"])])]),
            semanticText: "photos of the sea",
            scoredPool: ["L-existing": 0.5],
            evaluatedEmbedCount: 100)
        saved.pendingFinalization = false
        service.saveInterpretationForTesting(saved, for: albumID)
        return service
    }

    @Test("クエリ埋め込みが取れなかった回は評価済み件数を進めない（次回また採点される）")
    func failedEmbeddingDoesNotAdvanceCount() async {
        let albumID = "album-fail"
        let service = await makeService(embedder: FailingEmbedder(), albumID: albumID)

        _ = await service.refreshIncremental(newRefKeys: ["L-new"], current: [makeAlbum(id: albumID)])

        let after = service.savedInterpretationForTesting(albumID)
        #expect(after?.evaluatedEmbedCount == 100,
                "採点していないのに評価済みにした（この写真は二度と評価されない）")
    }

    @Test("採点できた回は評価済み件数を進める")
    func successfulEmbeddingAdvancesCount() async {
        let albumID = "album-ok"
        let service = await makeService(embedder: FixedEmbedder(), albumID: albumID)

        _ = await service.refreshIncremental(newRefKeys: ["L-new"], current: [makeAlbum(id: albumID)])

        let after = service.savedInterpretationForTesting(albumID)
        #expect(after?.evaluatedEmbedCount == 101, "採点したのに評価済み件数が進んでいない")
    }
}
