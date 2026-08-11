import Foundation
import Testing
@testable import AutoAlbumCore

/// S7（ADR-102）: 証拠不足で保留になった写真を夜間キャプションの優先対象として覚えること。
/// キャプション網羅は 1%（お気に入り限定）しかないので、「いま証拠を必要としている写真」へ
/// 狙って配らないと、除外つきアルバムは索引が進んでも埋まらない。
@Suite("Evidence-starved caption priority")
@MainActor
struct EvidenceStarvedCaptionTests {

    private func photo(_ id: String) -> EnrichedPhoto {
        EnrichedPhoto(id: "L-\(id)", captureDate: nil, latitude: nil, longitude: nil, placeName: nil)
    }

    @Test("証拠ゲートで保留になった写真が優先リストへ載る")
    func gatedOutPhotosAreRecorded() async {
        let coordinator = AIAlbumVerificationCoordinator(tagStore: nil, verifier: nil)
        let spec = QuerySpec(clauses: [QueryClause([.not(.content(["people"]))])])
        // 証拠が一切無い（tagStore nil・顔 seam 未結線）＝人物除外では全員保留になる。
        let members = [photo("a"), photo("b")]
        let gated = await coordinator.evidenceGatedIfExcluding(members, spec: spec)
        #expect(gated.isEmpty)
        #expect(coordinator.evidenceStarvedRefKeys == ["L-a", "L-b"],
                "保留になった写真が優先リストに載っていない")
    }

    @Test("別アルバムの保留は統合され、重複しない")
    func starvedListMergesAcrossAlbums() async {
        let coordinator = AIAlbumVerificationCoordinator(tagStore: nil, verifier: nil)
        let spec = QuerySpec(clauses: [QueryClause([.not(.content(["people"]))])])
        _ = await coordinator.evidenceGatedIfExcluding([photo("a"), photo("b")], spec: spec)
        _ = await coordinator.evidenceGatedIfExcluding([photo("b"), photo("c")], spec: spec)
        #expect(coordinator.evidenceStarvedRefKeys == ["L-a", "L-b", "L-c"])
    }

    @Test("除外の無いアルバムは記録しない（素通しの経路）")
    func noExclusionNoRecording() async {
        let coordinator = AIAlbumVerificationCoordinator(tagStore: nil, verifier: nil)
        let spec = QuerySpec(clauses: [QueryClause([.content(["dog"])])])
        let members = [photo("a")]
        let gated = await coordinator.evidenceGatedIfExcluding(members, spec: spec)
        #expect(gated.count == 1)
        #expect(coordinator.evidenceStarvedRefKeys.isEmpty)
    }

    @Test("上限を超えたら古い保留から捨てる")
    func starvedListIsBounded() async {
        let coordinator = AIAlbumVerificationCoordinator(tagStore: nil, verifier: nil)
        let spec = QuerySpec(clauses: [QueryClause([.not(.content(["people"]))])])
        let many = (0..<(AIAlbumVerificationCoordinator.maxStarvedTracked + 50)).map { photo("p\($0)") }
        _ = await coordinator.evidenceGatedIfExcluding(many, spec: spec)
        #expect(coordinator.evidenceStarvedRefKeys.count == AIAlbumVerificationCoordinator.maxStarvedTracked)
        #expect(coordinator.evidenceStarvedRefKeys.last == "L-p\(many.count - 1)",
                "新しい保留が残るべき（古い方から捨てる）")
    }
}
