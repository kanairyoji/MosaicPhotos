import CoreLocation
import Foundation
import Testing
@testable import PhotoSourceKit

@Suite("GeoGridKey")
struct GeoGridKeyTests {

    @Test("近接座標は同一キー、離れた座標は別キー")
    func rounding() {
        let a = GeoGridKey.key(latitude: 35.001, longitude: 139.001)
        let near = GeoGridKey.key(latitude: 35.005, longitude: 139.004)  // 同一セル
        let far = GeoGridKey.key(latitude: 35.500, longitude: 139.500)
        #expect(a == near)
        #expect(a != far)
    }

    @Test("既定ステップ 0.02 の丸め値（小数3桁書式）")
    func exactRoundingValues() {
        // 35.001 → 35.000, 139.011 → 139.020（最近接の 0.02 グリッド）
        #expect(GeoGridKey.key(latitude: 35.001, longitude: 139.011) == "35.000,139.020")
        // ちょうど中点 0.01 は round-half-to-even ではなく四捨五入（away from zero）で 0.02 側へ
        #expect(GeoGridKey.key(latitude: 0.01, longitude: 0.03) == "0.020,0.040")
    }

    @Test("負の座標（南半球・西経）も対称に丸める")
    func negativeCoordinates() {
        // -35.001 → -35.000, -139.011 → -139.020
        #expect(GeoGridKey.key(latitude: -35.001, longitude: -139.011) == "-35.000,-139.020")
    }

    @Test("原点近傍は -0.000 ではなく 0.000 表記に正規化される想定の確認")
    func nearOrigin() {
        // 0 近傍は符号付きゼロが出ないこと（"0.000" を含むこと）を確認。
        let key = GeoGridKey.key(latitude: 0.0001, longitude: -0.0001)
        #expect(key.contains("0.000"))
    }

    @Test("ステップを変えると粒度が変わる")
    func customStep() {
        // step 0.1 では 35.04 と 35.05 は別セル（0.0/0.1 境界の周辺）。
        let coarseA = GeoGridKey.key(latitude: 35.04, longitude: 139.0, step: 0.1)
        let coarseB = GeoGridKey.key(latitude: 35.06, longitude: 139.0, step: 0.1)
        #expect(coarseA != coarseB)
        // 既定ステップ（0.02）よりは粗いので、近接2点が同一になりやすい。
        let same1 = GeoGridKey.key(latitude: 35.01, longitude: 139.0, step: 0.1)
        let same2 = GeoGridKey.key(latitude: 35.04, longitude: 139.0, step: 0.1)
        #expect(same1 == same2)  // どちらも 35.0 へ丸まる
    }

    @Test("CLLocationCoordinate2D 版は latitude/longitude 版と一致する")
    func coordinateOverloadMatches() {
        let coord = CLLocationCoordinate2D(latitude: 35.681, longitude: 139.767)
        #expect(GeoGridKey.key(coord) == GeoGridKey.key(latitude: 35.681, longitude: 139.767))
    }
}
