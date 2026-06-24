import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("dedupByLinkKey")
struct DedupTests {
    private func photo(_ id: String, linkKey: String?) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: nil, latitude: nil, longitude: nil, placeName: nil, linkKey: linkKey)
    }

    @Test("同じ linkKey はローカルを優先しクラウド重複を落とす")
    func prefersLocal() {
        let result = dedupByLinkKey([
            photo("C-/backup/a.jpg", linkKey: "/backup/a.jpg"),
            photo("L-local-a", linkKey: "/backup/a.jpg"),
        ])
        #expect(result.count == 1)
        #expect(result[0].id == "L-local-a")
    }

    @Test("ローカルが無ければクラウドが残る（退避後）")
    func cloudSurvivesWithoutLocal() {
        let result = dedupByLinkKey([photo("C-/backup/a.jpg", linkKey: "/backup/a.jpg")])
        #expect(result.count == 1)
        #expect(result[0].id == "C-/backup/a.jpg")
    }

    @Test("linkKey が nil の写真はそのまま残す")
    func keepsUnlinked() {
        let result = dedupByLinkKey([
            photo("L-x", linkKey: nil),
            photo("C-/other/y.jpg", linkKey: "/other/y.jpg"),
        ])
        #expect(result.count == 2)
    }
}

@Suite("PhotoRef")
struct PhotoRefTests {
    @Test("encode/decode が往復する")
    func roundTrip() {
        #expect(PhotoRef.local("abc").encoded == "L-abc")
        #expect(PhotoRef.cloud("/p/q.jpg").encoded == "C-/p/q.jpg")
        #expect(PhotoRef.decode("L-abc") == .local("abc"))
        #expect(PhotoRef.decode("C-/p/q.jpg") == .cloud("/p/q.jpg"))
        #expect(PhotoRef.decode("xyz") == nil)
    }

    @Test("AutoAlbumInfo はメンバーをローカル/クラウドに分解する")
    func splitsMembers() {
        let info = AutoAlbumInfo(id: "i", strategyID: "s", title: "t", placeName: nil, places: [],
                                 country: nil, people: [],
                                 startDate: .distantPast, endDate: .distantPast, coverRef: "L-c",
                                 memberRefs: ["L-a", "C-/x.jpg", "L-b"], photoCount: 3, representativeDate: .distantPast,
                                 latitude: nil, longitude: nil)
        #expect(info.localIdentifiers == ["a", "b"])
        #expect(info.cloudPaths == ["/x.jpg"])
    }
}
