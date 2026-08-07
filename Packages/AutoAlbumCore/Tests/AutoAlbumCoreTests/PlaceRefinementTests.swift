import CoreLocation
import Foundation
import PhotoSourceKit
import Testing
@testable import AutoAlbumCore

/// 地名高精度化の対象セル抽出と台帳伝播（純ロジック）を検証する。
@Suite("PlaceRefinement")
struct PlaceRefinementTests {

    private func photo(_ id: String, lat: Double?, lon: Double?,
                       place: String? = nil, country: String? = nil) -> EnrichedPhoto {
        EnrichedPhoto(id: id, captureDate: nil, latitude: lat, longitude: lon,
                      placeName: place, country: country)
    }

    // MARK: - cellCentroids

    @Test("枚数の多いセルが先頭に来る")
    func centroidsOrderedByCount() {
        // セル A（35.00, 135.00 近傍）に 3 枚、セル B（36.00, 136.00 近傍）に 1 枚。
        let photos = [
            photo("L-1", lat: 35.001, lon: 135.001),
            photo("L-2", lat: 35.002, lon: 135.002),
            photo("L-3", lat: 35.003, lon: 135.003),
            photo("L-4", lat: 36.000, lon: 136.000),
        ]
        let cells = PlaceRefinement.cellCentroids(photos: photos)
        #expect(cells.count == 2)
        #expect(abs(cells[0].latitude - 35.002) < 0.0001)   // セル A の重心が先
        #expect(abs(cells[0].longitude - 135.002) < 0.0001)
    }

    @Test("重心は元のセルと同じグリッドキーに丸まる")
    func centroidStaysInCell() {
        let photos = [
            photo("L-1", lat: 35.001, lon: 135.001),
            photo("L-2", lat: 35.004, lon: 135.004),
        ]
        let cells = PlaceRefinement.cellCentroids(photos: photos)
        #expect(cells.count == 1)
        let originalKey = GeoGridKey.key(latitude: 35.001, longitude: 135.001)
        let centroidKey = GeoGridKey.key(latitude: cells[0].latitude, longitude: cells[0].longitude)
        #expect(centroidKey == originalKey)
    }

    @Test("座標なし・非有限は無視する")
    func centroidsSkipInvalid() {
        let photos = [
            photo("L-1", lat: nil, lon: nil),
            photo("L-2", lat: .nan, lon: 135.0),
            photo("L-3", lat: 35.0, lon: 135.0),
        ]
        #expect(PlaceRefinement.cellCentroids(photos: photos).count == 1)
    }

    // MARK: - ledgerChanges

    @Test("キャッシュの地名と台帳が違う写真だけ差分になる")
    func changesOnlyWhenDifferent() {
        let key = "ja:" + GeoGridKey.key(latitude: 35.0, longitude: 135.0)
        let cache = [key: PlaceComponents(locality: "嵐山", subLocality: nil,
                                          administrativeArea: "京都府", country: "日本", refined: true)]
        let photos = [
            photo("L-old", lat: 35.0, lon: 135.0, place: "京都市", country: "日本"),   // 変わる
            photo("L-ok", lat: 35.0, lon: 135.0, place: "嵐山", country: "日本"),      // 一致＝差分なし
        ]
        let changes = PlaceRefinement.ledgerChanges(photos: photos, cache: cache, keyPrefix: "ja:")
        #expect(changes == [PlaceUpdate(refKey: "L-old", placeName: "嵐山", country: "日本")])
    }

    @Test("locality が無ければ admin → country の順で選ぶ（cityName と同一規則）")
    func changesFallbackOrder() {
        let key = "ja:" + GeoGridKey.key(latitude: 35.0, longitude: 135.0)
        let cache = [key: PlaceComponents(locality: nil, administrativeArea: "京都府",
                                          country: "日本", refined: true)]
        let photos = [photo("L-1", lat: 35.0, lon: 135.0, place: "京都市", country: "日本")]
        let changes = PlaceRefinement.ledgerChanges(photos: photos, cache: cache, keyPrefix: "ja:")
        #expect(changes.first?.placeName == "京都府")
    }

    @Test("キャッシュに無いセル・空コンポーネントは触らない（nil で上書きしない）")
    func changesSkipUnresolved() {
        let emptyKey = "ja:" + GeoGridKey.key(latitude: 36.0, longitude: 136.0)
        let cache = [emptyKey: PlaceComponents(locality: nil, administrativeArea: nil, country: nil)]
        let photos = [
            photo("L-1", lat: 35.0, lon: 135.0, place: "京都市"),   // キャッシュに無い
            photo("L-2", lat: 36.0, lon: 136.0, place: "金沢市"),   // 空（圏外）
        ]
        #expect(PlaceRefinement.ledgerChanges(photos: photos, cache: cache, keyPrefix: "ja:").isEmpty)
    }

    @Test("言語接頭辞が違うキャッシュ項目は使わない")
    func changesRespectPrefix() {
        let key = "en:" + GeoGridKey.key(latitude: 35.0, longitude: 135.0)
        let cache = [key: PlaceComponents(locality: "Kyoto", administrativeArea: nil,
                                          country: "Japan", refined: true)]
        let photos = [photo("L-1", lat: 35.0, lon: 135.0, place: "京都市")]
        #expect(PlaceRefinement.ledgerChanges(photos: photos, cache: cache, keyPrefix: "ja:").isEmpty)
    }
}
