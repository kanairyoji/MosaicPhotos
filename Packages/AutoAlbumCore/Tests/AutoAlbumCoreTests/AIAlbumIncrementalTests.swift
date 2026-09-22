import Foundation
import Testing
@testable import AutoAlbumCore

/// 増分再評価（`refreshIncremental`）の**今の挙動**を固定する（リファクタリングの前提）。
///
/// ⚠️ 未解決の台帳（unresolved-problems.md「増分評価が全評価と違う規則で動いている」6 件）は
/// ここでは直さない。アルバムの中身が変わる修正は、クエリ集ハーネスで測ってから決める規則。
@Suite("AIAlbum incremental — 振る舞いの固定", .serialized)
@MainActor
struct AIAlbumIncrementalTests {

    private struct FixedEmbedder: TextEmbedder {
        var isAvailable: Bool { true }
        func embed(_ text: String) async -> [Float]? { [1, 0, 0] }
        func prewarm() async {}
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func vector(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }

    private func photo(_ id: String, _ v: [Float], offset: TimeInterval,
                       located: Bool = false) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: base.addingTimeInterval(offset),
                      latitude: located ? 35 : nil, longitude: located ? 139 : nil,
                      placeName: nil, clipVector: vector(v))
    }

    private func album(id: String, criteria: String) -> AutoAlbumInfo {
        AutoAlbumInfo(id: id, strategyID: "ai", title: "T", placeName: nil, places: [],
                      country: nil, people: [], startDate: base, endDate: base,
                      coverRef: nil, memberRefs: ["L-existing"], photoCount: 1,
                      representativeDate: base, latitude: nil, longitude: nil, criteria: criteria)
    }

    /// 既存 1 枚＋新規の写真を入れ、解釈を保存したサービス。
    private func makeService(newPhotos: [EnrichedPhoto], spec: QuerySpec, criteria: String,
                             albumID: String, evaluated: Int = 1)
        async -> (AIAlbumService, AutoAlbumStore) {
        let store = AutoAlbumStore(isStoredInMemoryOnly: true)
        let existing = photo("L-existing", [1, 0, 0], offset: 0, located: true)
        await store.upsert([existing] + newPhotos)
        _ = await store.upsertImportedEmbeddings(([existing] + newPhotos).map {
            (refKey: $0.id, vectorHalf: ClipMath.encodeHalf(ClipMath.decode($0.clipVector!)!))
        })
        let service = AIAlbumService(store: store, tagStore: nil,
                                     understanding: RuleBasedQueryUnderstanding(),
                                     textEmbedder: FixedEmbedder())
        var saved = SavedInterpretation(criteria: criteria, spec: spec,
                                        semanticText: "photos of the sea",
                                        scoredPool: ["L-existing": 0.9],
                                        evaluatedEmbedCount: evaluated)
        saved.pendingFinalization = false
        service.saveInterpretationForTesting(saved, for: albumID)
        return (service, store)
    }

    @Test("意味採点の経路: 条件に合う新しい写真は入り、合わない写真は入らない")
    func semanticPathAddsMatchingPhotos() async {
        let spec = QuerySpec(clauses: [QueryClause([.content(["sea"])])])
        let (service, _) = await makeService(
            newPhotos: [photo("L-match", [1, 0, 0], offset: 100),
                        photo("L-other", [0, 1, 0], offset: 200)],
            spec: spec, criteria: "海の写真", albumID: "a-sem")

        let result = await service.refreshIncremental(newRefKeys: ["L-match", "L-other"],
                                                      current: [album(id: "a-sem", criteria: "海の写真")])
        let members = Set(result.albums.first?.memberRefs ?? [])
        #expect(members.contains("L-existing"), "既存のメンバーを落とした")
        #expect(members.contains("L-match"), "条件に合う新しい写真が入らない")
        #expect(!members.contains("L-other"), "条件に合わない写真が入った")
        #expect(result.deferredRefKeys.isEmpty)
        #expect(service.savedInterpretationForTesting("a-sem")?.scoredPool["L-match"] != nil,
                "採点した写真をプールへ足していない")
    }

    @Test("ハード条件だけの経路: 条件を満たす新しい写真だけが入り、評価済みに数える")
    func hardOnlyPathAddsPassingPhotos() async {
        let spec = QuerySpec(clauses: [QueryClause([.hasLocation])])
        let (service, _) = await makeService(
            newPhotos: [photo("L-geo", [0, 1, 0], offset: 100, located: true),
                        photo("L-nogeo", [0, 1, 0], offset: 200)],
            spec: spec, criteria: "位置情報のある写真", albumID: "a-hard")

        let result = await service.refreshIncremental(newRefKeys: ["L-geo", "L-nogeo"],
                                                      current: [album(id: "a-hard", criteria: "位置情報のある写真")])
        let members = Set(result.albums.first?.memberRefs ?? [])
        #expect(members == ["L-existing", "L-geo"])
        #expect(service.savedInterpretationForTesting("a-hard")?.evaluatedEmbedCount == 3)
    }

    @Test("評価済み件数は、埋め込みの総数を超えない（持ち越した分を再処理しても）")
    func evaluatedCountIsCapped() async {
        let spec = QuerySpec(clauses: [QueryClause([.content(["sea"])])])
        let (service, _) = await makeService(
            newPhotos: [photo("L-match", [1, 0, 0], offset: 100)],
            spec: spec, criteria: "海の写真", albumID: "a-cap", evaluated: 2)
        _ = await service.refreshIncremental(newRefKeys: ["L-match"],
                                             current: [album(id: "a-cap", criteria: "海の写真")])
        // 埋め込みは 2 枚（既存＋新規）。既に 2 と数えていたので、再処理しても 2 のまま。
        #expect(service.savedInterpretationForTesting("a-cap")?.evaluatedEmbedCount == 2)
    }

    @Test("解釈が保存されていない（まだ評価していない）アルバムは触らない")
    func unevaluatedAlbumIsUntouched() async {
        let spec = QuerySpec(clauses: [QueryClause([.content(["sea"])])])
        let (service, _) = await makeService(
            newPhotos: [photo("L-match", [1, 0, 0], offset: 100)],
            spec: spec, criteria: "海の写真", albumID: "a-new", evaluated: 0)
        let result = await service.refreshIncremental(newRefKeys: ["L-match"],
                                                      current: [album(id: "a-new", criteria: "海の写真")])
        #expect(result.albums.first?.memberRefs == ["L-existing"])
    }
}

/// 増分再評価の純ロジック（`AIAlbumIncremental`）。
@Suite("AIAlbum incremental — 規則")
struct AIAlbumIncrementalRuleTests {

    @Test("評価済み件数は足した分だけ進み、埋め込みの総数で頭打ち・既に超えていれば減らさない")
    func advancedCount() {
        #expect(AIAlbumIncremental.advancedEvaluatedCount(10, adding: 3, embeddedNow: 100) == 13)
        #expect(AIAlbumIncremental.advancedEvaluatedCount(98, adding: 5, embeddedNow: 100) == 100)
        #expect(AIAlbumIncremental.advancedEvaluatedCount(120, adding: 5, embeddedNow: 100) == 120)
    }

    @Test("内容語が無くハード条件だけのアルバムは、意味採点をしない経路")
    func hardOnlyDetection() {
        #expect(AIAlbumIncremental.isHardOnly(QuerySpec(clauses: [QueryClause([.hasLocation])])))
        #expect(!AIAlbumIncremental.isHardOnly(QuerySpec(clauses: [QueryClause([.content(["sea"])])])))
        #expect(!AIAlbumIncremental.isHardOnly(QuerySpec(clauses: [QueryClause([.hasLocation,
                                                                                .content(["sea"])])])))
        // ハード条件も内容語も無い（除外も無い）は、ハードだけの経路ではない。
        #expect(!AIAlbumIncremental.isHardOnly(QuerySpec(clauses: [])))
    }

    /// 人系の除外（「人が写っていない」）は、実測の人数を主・顔の数を補助にし、
    /// **証拠が無い写真は通さない**（ADR-100）。
    @Test("人系の除外: 人数 0 だけが通り、証拠の無い写真は通さない")
    func peopleExclusionNeedsEvidence() {
        func photo(_ id: String) -> EnrichedPhoto {
            EnrichedPhoto(id: id, captureDate: nil, latitude: nil, longitude: nil, placeName: nil,
                          clipVector: nil)
        }
        let vector: Data = [Float(1), 0, 0].withUnsafeBufferPointer { Data(buffer: $0) }
        let photos = ["L-none", "L-human", "L-face", "L-unknown"].map(photo)
        let vectors = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, vector) })
        let query = QueryEmbedder.QueryVectors(positives: [[1, 0, 0]], negatives: [])
        let result = AIAlbumIncremental.scoreNewPhotos(
            photos, vectors: vectors, spec: QuerySpec(clauses: [QueryClause([.content(["sea"])])]),
            now: Date(), peopleMap: nil, signals: QuerySignals(),
            faceCounts: ["L-face": 1, "L-none": 0], humanCounts: ["L-human": 2, "L-none": 0],
            query: query)
        #expect(result.passed.map(\.id) == ["L-none"])
        #expect(Set(result.scores.keys) == ["L-none"])
    }
}
