import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("TimePlaceStrategy (trip extraction)")
struct TimePlaceStrategyTests {

    private let strategy = TimePlaceStrategy()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // テスト用パラメータ（最小枚数3・常用は3日以上・25km）。
    private let params = AlbumGenParams(
        gridStepDegrees: 0.02, frequentMinDistinctDays: 3,
        homeDistanceMeters: 25_000, minTripPhotos: 3)

    private let tokyo = (lat: 35.681, lon: 139.767)
    private let osaka = (lat: 34.693, lon: 135.502)   // 東京から ~400km

    /// day=異なる日, secInDay=その日の中の秒オフセット。
    private func photo(_ id: String, day: Int, sec: Double, _ coord: (lat: Double, lon: Double),
                       place: String? = nil) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: base.addingTimeInterval(Double(day) * 86_400 + sec),
                      latitude: coord.lat, longitude: coord.lon, placeName: place)
    }

    @Test("常用地点から離れたまとまりだけ旅行アルバムになる")
    func extractsTripAwayFromHome() {
        // 大阪で1日に5枚（常用でない・遠い）→ 旅行。
        let photos = (0..<5).map { photo("o\($0)", day: 10, sec: Double($0) * 60, osaka, place: "Osaka") }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].placeName == "Osaka")
        #expect(albums[0].photoCount == 5)
    }

    @Test("常用地点（異なる日数が閾値以上）の写真は旅行にしない")
    func excludesFrequentPlace() {
        var photos: [EnrichedPhoto] = []
        // 東京で 4 日（≥3）→ 常用地点。各日 1 枚。
        for d in 0..<4 { photos.append(photo("t\(d)", day: d, sec: 0, tokyo, place: "Tokyo")) }
        // 東京で「大量に撮った日」5枚（≥minTrip）も、常用地点付近なので除外されるべき。
        for i in 0..<5 { photos.append(photo("tb\(i)", day: 20, sec: Double(i) * 60, tokyo, place: "Tokyo")) }
        // 大阪の旅行 5枚。
        for i in 0..<5 { photos.append(photo("o\(i)", day: 30, sec: Double(i) * 60, osaka, place: "Osaka")) }

        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].placeName == "Osaka")
    }

    @Test("複数の常用地点（自宅＋職場）をどちらも除外する")
    func excludesMultipleFrequentPlaces() {
        let office = (lat: 35.690, lon: 139.700)   // 東京近郊だが別セル
        var photos: [EnrichedPhoto] = []
        for d in 0..<3 { photos.append(photo("h\(d)", day: d, sec: 0, tokyo, place: "Home")) }
        for d in 0..<3 { photos.append(photo("w\(d)", day: d, sec: 3600, office, place: "Office")) }
        // 行きつけ2箇所に大量の日も、両方除外。
        for i in 0..<5 { photos.append(photo("hb\(i)", day: 10, sec: Double(i) * 60, tokyo)) }
        for i in 0..<5 { photos.append(photo("wb\(i)", day: 11, sec: Double(i) * 60, office)) }
        // 旅行のみ採用。
        for i in 0..<5 { photos.append(photo("o\(i)", day: 20, sec: Double(i) * 60, osaka, place: "Osaka")) }

        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].placeName == "Osaka")
    }

    @Test("最小枚数未満の旅行は破棄する")
    func dropsSmallTrips() {
        let photos = [photo("a", day: 5, sec: 0, osaka), photo("b", day: 5, sec: 60, osaka)]   // 2枚 < 3
        #expect(strategy.makeAlbums(from: photos, params: params).isEmpty)
    }

    @Test("時間ギャップで別の旅行に分割する")
    func splitsByTimeGap() {
        var photos: [EnrichedPhoto] = []
        for i in 0..<3 { photos.append(photo("a\(i)", day: 10, sec: Double(i) * 60, osaka, place: "Osaka")) }
        for i in 0..<3 { photos.append(photo("b\(i)", day: 40, sec: Double(i) * 60, osaka, place: "Osaka")) }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 2)
        #expect(albums[0].endDate > albums[1].endDate)   // 新しい順
    }

    @Test("座標の無い写真は旅行にならない")
    func ignoresLocationless() {
        let undated = (0..<5).map {
            EnrichedPhoto(id: "x\($0)", captureDate: base.addingTimeInterval(Double($0) * 60),
                          latitude: nil, longitude: nil, placeName: nil)
        }
        #expect(strategy.makeAlbums(from: undated, params: params).isEmpty)
    }

    @Test("常用地点が無ければ（バラけた写真）まとまりは旅行になる")
    func noFrequentMeansAllTrips() {
        // 各日別の遠い場所に5枚ずつ→常用地点ゼロ→両方旅行。
        var photos: [EnrichedPhoto] = []
        for i in 0..<5 { photos.append(photo("o\(i)", day: 10, sec: Double(i) * 60, osaka, place: "Osaka")) }
        for i in 0..<5 { photos.append(photo("t\(i)", day: 40, sec: Double(i) * 60, tokyo, place: "Tokyo")) }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 2)
    }

    @Test("時間が連続していれば複数都市を1つの旅行にまとめる")
    func mergesMultipleCitiesInOneTrip() {
        let kyoto = (lat: 35.011, lon: 135.768)   // 大阪から ~40km（距離では区切らない）
        var photos: [EnrichedPhoto] = []
        for i in 0..<3 { photos.append(photo("o\(i)", day: 10, sec: Double(i) * 60, osaka, place: "Osaka")) }
        for i in 0..<3 { photos.append(photo("k\(i)", day: 10, sec: 180 + Double(i) * 60, kyoto, place: "Kyoto")) }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].photoCount == 6)
        #expect(Set(albums[0].places) == ["Osaka", "Kyoto"])
    }

    @Test("スクリーンショットは旅行のメンバーから除外する")
    func excludesScreenshots() {
        var photos: [EnrichedPhoto] = []
        for i in 0..<5 { photos.append(photo("o\(i)", day: 10, sec: Double(i) * 60, osaka, place: "Osaka")) }
        for i in 0..<2 {
            photos.append(EnrichedPhoto(
                id: "s\(i)", captureDate: base.addingTimeInterval(10 * 86_400 + 300 + Double(i) * 60),
                latitude: osaka.lat, longitude: osaka.lon, placeName: "Osaka", isScreenshot: true))
        }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].photoCount == 5)
        #expect(albums[0].memberRefs.allSatisfy { !$0.hasPrefix("s") })
    }

    @Test("座標の無い写真は前後のGPSから補完して旅行に含める")
    func backfillsMissingCoordinates() {
        let located1 = photo("o0", day: 10, sec: 0, osaka, place: "Osaka")
        let gap = EnrichedPhoto(id: "x", captureDate: base.addingTimeInterval(10 * 86_400 + 60),
                                latitude: nil, longitude: nil, placeName: nil)
        let located2 = photo("o2", day: 10, sec: 120, osaka, place: "Osaka")
        let albums = strategy.makeAlbums(from: [located1, gap, located2], params: params)
        #expect(albums.count == 1)
        #expect(albums[0].photoCount == 3)   // x も補完されて旅行に含まれる
    }

    @Test("多日にまたがる旅行は1アルバムにまとまり、日あたり少枚数でも破棄されない")
    func mergesConsecutiveDaysIntoOneTrip() {
        // 大阪に2日連続・各日2枚（日ごとなら2枚<3で全滅するが、まとめれば4枚で成立）。
        var photos: [EnrichedPhoto] = []
        for d in 10...11 {
            for i in 0..<2 { photos.append(photo("o\(d)_\(i)", day: d, sec: Double(i) * 60, osaka, place: "Osaka")) }
        }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].photoCount == 4)
    }

    @Test("在宅日を挟むと別々の旅行に分割する")
    func splitsTripsAcrossHomeDay() {
        var photos: [EnrichedPhoto] = []
        // 東京を常用地点にする（異なる3日）。
        for d in 0..<3 { photos.append(photo("h\(d)", day: d, sec: 0, tokyo, place: "Tokyo")) }
        // 旅行A（大阪 day10）→ 在宅（東京 day11）→ 旅行B（大阪 day12）。
        for i in 0..<3 { photos.append(photo("a\(i)", day: 10, sec: Double(i) * 60, osaka, place: "Osaka")) }
        photos.append(photo("home", day: 11, sec: 0, tokyo, place: "Tokyo"))
        for i in 0..<3 { photos.append(photo("b\(i)", day: 12, sec: Double(i) * 60, osaka, place: "Osaka")) }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 2)
    }

    @Test("カバーはお気に入りを優先して選ぶ")
    func coverPrefersFavorite() {
        var photos: [EnrichedPhoto] = []
        for i in 0..<5 {
            photos.append(EnrichedPhoto(
                id: "o\(i)", captureDate: base.addingTimeInterval(10 * 86_400 + Double(i) * 60),
                latitude: osaka.lat, longitude: osaka.lon, placeName: "Osaka",
                isFavorite: i == 3))   // o3 だけお気に入り
        }
        let albums = strategy.makeAlbums(from: photos, params: params)
        #expect(albums.count == 1)
        #expect(albums[0].coverRef == "o3")
    }
}
