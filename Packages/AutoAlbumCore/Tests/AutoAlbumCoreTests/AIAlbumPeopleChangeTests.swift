import Foundation
import Testing
@testable import AutoAlbumCore

/// 人物の手動修正（「この写真は XX ではない」等）の直後に、人物条件を持つ AI アルバムから
/// 条件を満たさなくなった写真を外す（実フィードバック: AI アルバムで直しても変化なし）。
@Suite("AI アルバム — 人物修正の反映", .serialized)
@MainActor
struct AIAlbumPeopleChangeTests {

    private func vector(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    private func makeAlbum(id: String, members: [String]) -> AutoAlbumInfo {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return AutoAlbumInfo(id: id, strategyID: "ai", title: "太郎", placeName: nil, places: [],
                             country: nil, people: ["太郎"], startDate: now, endDate: now,
                             coverRef: nil, memberRefs: members, photoCount: members.count,
                             representativeDate: now, latitude: nil, longitude: nil,
                             criteria: "太郎の写真")
    }

    @Test("「XX ではない」にした写真だけがアルバムから外れ、他は残る。追加はしない")
    func dropsOnlyPhotosThatNoLongerMatch() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        await store.upsert(["L-a", "L-b", "L-c"].map {
            EnrichedPhoto(id: $0, captureDate: t, latitude: nil, longitude: nil, placeName: nil,
                          clipVector: vector([1, 0, 0]))
        })
        let service = AIAlbumService(store: store, tagStore: nil,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: nil)
        var saved = SavedInterpretation(
            criteria: "太郎の写真",
            spec: QuerySpec(clauses: [QueryClause([.people(["太郎"])])]),
            semanticText: "photos of taro", scoredPool: [:], evaluatedEmbedCount: 3)
        saved.pendingFinalization = false
        service.saveInterpretationForTesting(saved, for: "album")
        // 修正後の「いまの人物」: b は太郎ではなくなった。c は新たに太郎になった（＝追加は次の再評価）。
        service.peopleByRefKeyProvider = { ["L-a": ["太郎"], "L-c": ["太郎"]] }

        let album = makeAlbum(id: "album", members: ["L-a", "L-b"])
        let pruned = await service.pruneAfterPeopleChange([album])
        #expect(pruned?.first?.memberRefs == ["L-a"], "外れた写真が残っている／関係ない写真まで消えた")

        // 変化が無ければ nil（書き戻さない）。
        let again = await service.pruneAfterPeopleChange(pruned ?? [album])
        #expect(again == nil)
    }

    @Test("人物条件の無いアルバムは触らない")
    func leavesAlbumsWithoutPeopleConditions() async {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let service = AIAlbumService(store: store, tagStore: nil,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: nil)
        var saved = SavedInterpretation(
            criteria: "太郎の写真", spec: QuerySpec(clauses: [QueryClause([.content(["sea"])])]),
            semanticText: "sea", scoredPool: [:], evaluatedEmbedCount: 1)
        saved.pendingFinalization = false
        service.saveInterpretationForTesting(saved, for: "album")
        service.peopleByRefKeyProvider = { [:] }
        let album = makeAlbum(id: "album", members: ["L-a"])
        #expect(await service.pruneAfterPeopleChange([album]) == nil)
    }
}
