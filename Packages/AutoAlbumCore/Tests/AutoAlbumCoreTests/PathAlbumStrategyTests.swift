import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("PathAlbumStrategy (folder-name albums)")
struct PathAlbumStrategyTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let rules = [PathAlbumRule(pattern: "^/Trips/(?<name>[^/]+)/", template: "${name}")]

    private func cloud(_ path: String, day: Int) -> EnrichedPhoto {
        EnrichedPhoto(id: PhotoRef.cloud(path).encoded,
                      captureDate: base.addingTimeInterval(Double(day) * 86_400),
                      latitude: nil, longitude: nil, placeName: nil, linkKey: path)
    }

    @Test("同じフォルダ名の写真を1アルバムにまとめる（GPS 不要）")
    func groupsByFolderName() {
        let strategy = PathAlbumStrategy(rules: rules, minPhotos: 2)
        let photos = [
            cloud("/Trips/Hawaii/a.jpg", day: 1),
            cloud("/Trips/Hawaii/b.jpg", day: 2),
            cloud("/Trips/Kyoto/c.jpg", day: 5),
            cloud("/Trips/Kyoto/d.jpg", day: 6),
        ]
        let drafts = strategy.makeAlbums(fromCloud: photos)
        #expect(drafts.count == 2)
        #expect(drafts.map(\.placeName) == ["Kyoto", "Hawaii"])   // 新しい順
        #expect(drafts.allSatisfy { $0.photoCount == 2 })
    }

    @Test("最小枚数未満のフォルダは採用しない")
    func dropsSmallFolders() {
        let strategy = PathAlbumStrategy(rules: rules, minPhotos: 2)
        let drafts = strategy.makeAlbums(fromCloud: [cloud("/Trips/Solo/a.jpg", day: 1)])
        #expect(drafts.isEmpty)
    }

    @Test("ルールに合わないパスは無視する")
    func ignoresUnmatchedPaths() {
        let strategy = PathAlbumStrategy(rules: rules, minPhotos: 1)
        let photos = [
            cloud("/Camera Uploads/2019-05-01.jpg", day: 1),
            cloud("/Trips/Bali/x.jpg", day: 2),
        ]
        let drafts = strategy.makeAlbums(fromCloud: photos)
        #expect(drafts.count == 1)
        #expect(drafts.first?.placeName == "Bali")
    }

    @Test("ローカル写真（cloudPath なし）は対象外")
    func ignoresLocalPhotos() {
        let strategy = PathAlbumStrategy(rules: rules, minPhotos: 1)
        let local = EnrichedPhoto(id: PhotoRef.local("L123").encoded, captureDate: base,
                                  latitude: nil, longitude: nil, placeName: nil)
        #expect(strategy.makeAlbums(fromCloud: [local]).isEmpty)
    }

    @Test("ルールが空なら何も作らない")
    func emptyRulesProduceNothing() {
        let strategy = PathAlbumStrategy(rules: [], minPhotos: 1)
        #expect(strategy.makeAlbums(fromCloud: [cloud("/Trips/Bali/x.jpg", day: 1)]).isEmpty)
    }
}
