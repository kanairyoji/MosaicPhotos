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
}
