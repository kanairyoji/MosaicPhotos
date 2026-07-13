import Foundation
import Testing
@testable import AutoAlbumCore

/// 人物条件の live 照合: 人物名（顔クラスタ）はリネーム/統合/成長で変わるため、
/// `EnrichedPhoto.people`（初回エンリッチ時の焼き込み・以後更新されない）でなく、
/// 検索時に PeopleEngine の**現在の**マップで照合する（実障害:「太郎と花子」が 0 件）。
@Suite("People live matching (焼き込みでなく現在のクラスタ名で照合)")
struct PeopleLiveMatchTests {
    private let now = Date()

    private func photo(_ id: String, baked: [String] = []) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: now, latitude: nil, longitude: nil,
                      placeName: nil, people: baked)
    }

    @Test("焼き込みが空でも live マップの名前でマッチする（後から命名したケース）")
    func liveMapMatchesWhenBakedEmpty() {
        // 実障害の再現: 写真は命名前にエンリッチ済み（people 空）→ 後から「山田太郎」と命名。
        let photos = [photo("a"), photo("b")]
        let live = [PhotoRef.local("a").encoded: ["山田太郎"]]
        let spec = QuerySpec(clauses: [QueryClause([.people(["山田太郎"])])])
        let result = QueryEvaluator.hardFilter(photos, spec: spec, now: now, peopleByRefKey: live)
        #expect(result.map(\.id) == [PhotoRef.local("a").encoded])
    }

    @Test("live マップ未収載の写真は焼き込みへフォールバック")
    func fallsBackToBakedWhenNotInMap() {
        let photos = [photo("a", baked: ["山田花子"])]
        let live: [String: [String]] = [:]   // 顔スキャン未カバー
        let spec = QuerySpec(clauses: [QueryClause([.people(["花子"])])])
        let result = QueryEvaluator.hardFilter(photos, spec: spec, now: now, peopleByRefKey: live)
        #expect(result.count == 1)
    }

    @Test("live マップはリネームを即反映（旧名の焼き込みではマッチしない）")
    func liveMapWinsOverStaleBaked() {
        // 「Person 3」→「山田太郎」へリネーム済み。焼き込みは旧名のまま。
        let photos = [photo("a", baked: ["Person 3"])]
        let live = [PhotoRef.local("a").encoded: ["山田太郎"]]
        let spec = QuerySpec(clauses: [QueryClause([.people(["太郎"])])])
        #expect(QueryEvaluator.hardFilter(photos, spec: spec, now: now,
                                          peopleByRefKey: live).count == 1)
        // live 無し（旧挙動）では旧名しか見えず 0 件＝この不具合の再現。
        #expect(QueryEvaluator.hardFilter(photos, spec: spec, now: now).isEmpty)
    }

    @Test("peopleAtLeast も live マップで数える")
    func peopleAtLeastUsesLiveMap() {
        let photos = [photo("a")]
        let live = [PhotoRef.local("a").encoded: ["山田太郎", "山田花子"]]
        let spec = QuerySpec(clauses: [QueryClause([.peopleAtLeast(2)])])
        #expect(QueryEvaluator.hardFilter(photos, spec: spec, now: now,
                                          peopleByRefKey: live).count == 1)
    }

    @Test("hasPeopleConditions は .people/.peopleAtLeast/.not(内包) を検出する")
    func hasPeopleConditionsDetects() {
        #expect(QuerySpec(clauses: [QueryClause([.people(["x"])])]).hasPeopleConditions)
        #expect(QuerySpec(clauses: [QueryClause([.peopleAtLeast(1)])]).hasPeopleConditions)
        #expect(QuerySpec(clauses: [QueryClause([.not(.people(["x"]))])]).hasPeopleConditions)
        #expect(!QuerySpec(clauses: [QueryClause([.content(["dog"])])]).hasPeopleConditions)
    }
}
