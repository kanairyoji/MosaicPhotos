import Testing
@testable import PhotoSourceKit

/// 同梱の都市DB（cities15000）でのオフライン逆ジオコーディングを検証する。
@Suite("OfflinePlaceDB")
struct OfflinePlaceDBTests {

    @Test("同梱DBが読み込まれる")
    func loaded() {
        #expect(OfflinePlaceDB.shared.isLoaded)
    }

    @Test("既知の座標を日本語の地名へ解決する（オフライン・即時）")
    func resolvesKnownCoordinates() {
        let kyoto = OfflinePlaceDB.shared.nearest(latitude: 35.01, longitude: 135.77)
        #expect(kyoto?.country == "日本")
        #expect(kyoto?.city?.contains("京都") == true)
        #expect(kyoto?.admin != nil)

        // 海外の主要都市も日本語名（alternateNames の ja）。
        let paris = OfflinePlaceDB.shared.nearest(latitude: 48.85, longitude: 2.35)
        #expect(paris?.city == "パリ")
        #expect(paris?.country == "フランス")
    }

    @Test("どの都市からも遠い座標（南極海など）は nil")
    func remoteIsNil() {
        #expect(OfflinePlaceDB.shared.nearest(latitude: -75, longitude: 0) == nil)
    }

    @Test("非有限な座標は nil")
    func nonFiniteIsNil() {
        #expect(OfflinePlaceDB.shared.nearest(latitude: .nan, longitude: 0) == nil)
    }
}
