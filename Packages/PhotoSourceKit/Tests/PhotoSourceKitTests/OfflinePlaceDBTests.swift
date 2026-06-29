import Testing
@testable import PhotoSourceKit

/// 同梱の都市DB（cities15000）でのオフライン逆ジオコーディングを検証する。
@Suite("OfflinePlaceDB")
struct OfflinePlaceDBTests {

    @Test("同梱DBが読み込まれる")
    func loaded() {
        #expect(OfflinePlaceDB.shared.isLoaded)
    }

    @Test("既知の座標を地名へ解決する（オフライン・即時）")
    func resolvesKnownCoordinates() {
        let kyoto = OfflinePlaceDB.shared.nearest(latitude: 35.01, longitude: 135.77)
        #expect(kyoto?.country == "Japan")
        #expect(kyoto?.city != nil)
        #expect(kyoto?.admin != nil)

        let paris = OfflinePlaceDB.shared.nearest(latitude: 48.85, longitude: 2.35)
        #expect(paris?.country == "France")
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
