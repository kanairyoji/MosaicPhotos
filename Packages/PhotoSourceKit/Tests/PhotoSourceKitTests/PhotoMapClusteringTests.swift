import CoreLocation
import Foundation
import Testing
@testable import PhotoSourceKit

/// 地図ピンの集約（純ロジック）。
///
/// ⚠️ ここが崩れると 86,000 枚がそのままアノテーションになり、地図が描画も操作もできなくなる。
/// 「ズームで粒度が変わる」「上限を超えない」「可視範囲の外を拾わない」を固定する。
@Suite("地図ピンの集約")
struct PhotoMapClusteringTests {

    private func candidate(_ lat: Double, _ lon: Double, day: Int = 1) -> PlaceCandidate {
        PlaceCandidate(latitude: lat, longitude: lon, isLocal: true,
                       identifier: "L-\(lat),\(lon),\(day)",
                       date: Date(timeIntervalSince1970: Double(day) * 86_400))
    }

    private func region(_ lat: Double, _ lon: Double, _ delta: Double) -> PhotoMapRegion {
        PhotoMapRegion(centerLatitude: lat, centerLongitude: lon,
                       latitudeDelta: delta, longitudeDelta: delta)
    }

    @Test("引きでは 1 つに畳まれ、寄ると分かれる")
    func zoomChangesGranularity() {
        // 約 2km 離れた 2 地点。
        let photos = [candidate(35.000, 139.000), candidate(35.020, 139.020)]

        let wide = PhotoMapClustering.pins(candidates: photos, region: region(35.01, 139.01, 5))
        #expect(wide.count == 1, "引いているのに分かれている: \(wide.count)")
        #expect(wide.first?.count == 2)

        let close = PhotoMapClustering.pins(candidates: photos, region: region(35.01, 139.01, 0.05))
        #expect(close.count == 2, "寄っているのに 1 つのまま: \(close.count)")
    }

    @Test("可視範囲の外の写真は拾わない")
    func ignoresPhotosOutsideTheRegion() {
        let photos = [candidate(35.0, 139.0), candidate(-33.9, 151.2)]   // 東京とシドニー
        let pins = PhotoMapClustering.pins(candidates: photos, region: region(35.0, 139.0, 1))
        #expect(pins.count == 1)
        #expect(pins.first?.members.first?.latitude == 35.0)
    }

    /// ⚠️ 上限は**跨いで**測る（上限より少ない範囲だけで測ると、上限が効いているのか
    /// 元から少ないのか区別できない・ADR-119 の教訓）。
    @Test("ピン数は上限を超えない（件数の多いセルが残る）")
    func respectsThePinLimit() {
        // 0.05° 間隔で 60 地点（緯度 3° ぶん）。粒度を細かく（columns=100 → step=0.04）して
        // 1 地点 1 セルにし、上限 20 を**跨がせる**。
        var photos: [PlaceCandidate] = []
        for i in 0..<60 {
            let lat = 35.0 + Double(i) * 0.05
            photos.append(candidate(lat, 139.0))
            if i == 7 { photos.append(candidate(lat + 0.001, 139.0, day: 2)) }   // 1 セルだけ 2 枚
        }
        let unlimited = PhotoMapClustering.pins(candidates: photos, region: region(36.5, 139.0, 4),
                                                columns: 100, pinLimit: 1_000)
        #expect(unlimited.count == 60, "fixture が 1 地点 1 セルになっていない: \(unlimited.count)")

        let pins = PhotoMapClustering.pins(candidates: photos, region: region(36.5, 139.0, 4),
                                           columns: 100, pinLimit: 20)
        #expect(pins.count == 20, "上限が効いていない: \(pins.count)")
        #expect(pins.contains { $0.count == 2 }, "件数の多いセルが落とされている")
    }

    /// ⚠️ 上限だけに頼らない設計であることの確認。粒度が画面幅に追従するので、
    /// **写真が何枚あってもセル数は `columns²` 程度**で頭打ちになる（上限は安全弁）。
    @Test("粒度そのものがピン数を有界にする（写真 1 万枚でも数百）")
    func gridItselfBoundsThePinCount() {
        var photos: [PlaceCandidate] = []
        for i in 0..<10_000 {
            photos.append(candidate(35.0 + Double(i % 100) * 0.01,
                                    139.0 + Double(i / 100) * 0.01))
        }
        let pins = PhotoMapClustering.pins(candidates: photos, region: region(35.5, 139.5, 2),
                                           pinLimit: 100_000)
        #expect(pins.count <= 400, "セル数が粒度で抑えられていない: \(pins.count)")
        #expect(pins.reduce(0) { $0 + $1.count } == 10_000, "写真を取りこぼしている")
    }

    @Test("代表は新しい写真・重心は写真の平均")
    func representativeAndCentroid() {
        let photos = [candidate(35.0, 139.0, day: 1), candidate(35.002, 139.002, day: 9)]
        let pins = PhotoMapClustering.pins(candidates: photos, region: region(35.001, 139.001, 1))
        #expect(pins.count == 1)
        #expect(pins.first?.representative.date == Date(timeIntervalSince1970: 9 * 86_400))
        #expect(abs((pins.first?.latitude ?? 0) - 35.001) < 0.0001)
    }

    /// 外れ値 1 枚で世界地図まで引かないこと（初期表示が「点が 1 つの世界地図」だと使えない）。
    @Test("初期表示の範囲は外れ値に引きずられない")
    func boundingRegionIgnoresOutliers() {
        var photos = (0..<40).map { candidate(35.0 + Double($0) * 0.001, 139.0) }
        photos.append(candidate(-33.9, 151.2))       // 1 枚だけシドニー
        let region = PhotoMapClustering.boundingRegion(of: photos)
        #expect(region != nil)
        #expect((region?.latitudeDelta ?? 99) < 1, "外れ値で引きすぎ: \(region?.latitudeDelta ?? -1)")
        #expect(abs((region?.centerLatitude ?? 0) - 35.02) < 0.1)
    }

    @Test("写真が無ければピンも範囲も無い")
    func emptyInput() {
        #expect(PhotoMapClustering.pins(candidates: [], region: .world).isEmpty)
        #expect(PhotoMapClustering.boundingRegion(of: []) == nil)
    }
}
