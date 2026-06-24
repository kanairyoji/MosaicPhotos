import Foundation
import Testing
@testable import PhotoSourceKit

private func candidate(_ id: String, isLocal: Bool, _ unix: TimeInterval?) -> PlaceCandidate {
    PlaceCandidate(latitude: 0, longitude: 0, isLocal: isLocal, identifier: id,
                   date: unix.map { Date(timeIntervalSince1970: $0) })
}

@Suite("PlaceGrouping.build")
struct PlaceGroupingTests {

    @Test("市ごとにまとめ、ローカル/クラウドを分離する")
    func groupsByCity() {
        let places = PlaceGrouping.build(byCity: [
            "Tokyo": [candidate("L1", isLocal: true, 100), candidate("C1", isLocal: false, 200)],
            "Osaka": [candidate("L2", isLocal: true, 50)],
        ])
        let tokyo = try! #require(places.first { $0.placeName == "Tokyo" })
        #expect(tokyo.photoCount == 2)
        #expect(tokyo.localIDs == ["L1"])
        #expect(tokyo.cloudPaths == ["C1"])
        #expect(tokyo.representativeDate == Date(timeIntervalSince1970: 200))
    }

    @Test("代表日時の昇順（下が新しい）に並ぶ")
    func sortedAscendingByRepresentativeDate() {
        let places = PlaceGrouping.build(byCity: [
            "A": [candidate("a", isLocal: true, 300)],
            "B": [candidate("b", isLocal: true, 100)],
            "C": [candidate("c", isLocal: true, 200)],
        ])
        #expect(places.map(\.placeName) == ["B", "C", "A"])  // 100 < 200 < 300
    }

    @Test("カバーはローカル優先、無ければ Dropbox")
    func coverPrefersLocal() {
        let mixed = PlaceGrouping.build(byCity: [
            "M": [candidate("L", isLocal: true, 10), candidate("C", isLocal: false, 20)],
        ])[0]
        #expect(mixed.coverLocalID == "L")
        #expect(mixed.coverCloudPath == nil)

        let cloudOnly = PlaceGrouping.build(byCity: [
            "K": [candidate("C9", isLocal: false, 10)],
        ])[0]
        #expect(cloudOnly.coverLocalID == nil)
        #expect(cloudOnly.coverCloudPath == "C9")
    }

    @Test("空入力は空")
    func empty() {
        #expect(PlaceGrouping.build(byCity: [:]).isEmpty)
    }
}
