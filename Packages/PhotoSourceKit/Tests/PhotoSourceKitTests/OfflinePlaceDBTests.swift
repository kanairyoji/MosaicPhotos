import Testing
@testable import PhotoSourceKit

/// 同梱の都市DB（cities15000）でのオフライン逆ジオコーディングを検証する。
@Suite("OfflinePlaceDB")
struct OfflinePlaceDBTests {

    @Test("同梱DBが読み込まれる")
    func loaded() {
        #expect(OfflinePlaceDB.shared.isLoaded)
    }

    @Test("既知の座標を日本語の地名へ解決する")
    func resolvesJapanese() {
        let kyoto = OfflinePlaceDB.shared.nearest(latitude: 35.01, longitude: 135.77, japanese: true)
        #expect(kyoto?.country == "日本")
        #expect(kyoto?.city?.contains("京都") == true)
        #expect(kyoto?.admin != nil)

        let paris = OfflinePlaceDB.shared.nearest(latitude: 48.85, longitude: 2.35, japanese: true)
        #expect(paris?.city == "パリ")
        #expect(paris?.country == "フランス")
    }

    @Test("英語指定では英語（ローマ字）の地名へ解決する")
    func resolvesEnglish() {
        let kyoto = OfflinePlaceDB.shared.nearest(latitude: 35.01, longitude: 135.77, japanese: false)
        #expect(kyoto?.country == "Japan")
        #expect(kyoto?.city?.contains("京都") == false)   // ローマ字（Kyoto 等）

        let paris = OfflinePlaceDB.shared.nearest(latitude: 48.85, longitude: 2.35, japanese: false)
        #expect(paris?.city == "Paris")
        #expect(paris?.country == "France")
    }

    @Test("どの都市からも遠い座標（南極海など）は nil")
    func remoteIsNil() {
        #expect(OfflinePlaceDB.shared.nearest(latitude: -75, longitude: 0, japanese: true) == nil)
    }

    @Test("非有限な座標は nil")
    func nonFiniteIsNil() {
        #expect(OfflinePlaceDB.shared.nearest(latitude: .nan, longitude: 0, japanese: false) == nil)
    }

    // MARK: - 距離格下げ（遠い最近傍に誤った市名を付けない）

    @Test("近い最近傍はそのまま（市名を保持）")
    func demotionNearKeepsCity() {
        let place = OfflinePlaceDB.Place(city: "京都市", admin: "京都府", country: "日本")
        let demoted = OfflinePlaceDB.demoted(place, distanceMeters: 10_000)
        #expect(demoted.city == "京都市")
        #expect(demoted.admin == "京都府")
    }

    @Test("市名の採用限界を超えたら県名へ格下げ")
    func demotionMidDropsCity() {
        let place = OfflinePlaceDB.Place(city: "京都市", admin: "京都府", country: "日本")
        let demoted = OfflinePlaceDB.demoted(place, distanceMeters: OfflinePlaceDB.cityMaxMeters + 1)
        #expect(demoted.city == nil)
        #expect(demoted.admin == "京都府")
        #expect(demoted.country == "日本")
    }

    @Test("県名の採用限界を超えたら国名のみ")
    func demotionFarCountryOnly() {
        let place = OfflinePlaceDB.Place(city: "京都市", admin: "京都府", country: "日本")
        let demoted = OfflinePlaceDB.demoted(place, distanceMeters: OfflinePlaceDB.adminMaxMeters + 1)
        #expect(demoted.city == nil)
        #expect(demoted.admin == nil)
        #expect(demoted.country == "日本")
    }

    @Test("都市中心の直近の座標は格下げされず市名が付く（結合）")
    func nearestWithinCityRangeKeepsCity() {
        // 京都市街の座標 → 最近傍まで数 km なので市名が残る。
        let kyoto = OfflinePlaceDB.shared.nearest(latitude: 35.01, longitude: 135.77, japanese: true)
        #expect(kyoto?.city?.contains("京都") == true)
    }
}
