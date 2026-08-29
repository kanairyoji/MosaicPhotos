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
    /// ここは上限だけを見たいので、画面上の最小間隔（吸収）は切って測る。
    @Test("ピン数は上限を超えない（件数の多いセルが残る）")
    func respectsThePinLimit() {
        var photos: [PlaceCandidate] = []
        for i in 0..<60 {
            let lat = 35.0 + Double(i) * 0.05
            photos.append(candidate(lat, 139.0))
            if i == 7 { photos.append(candidate(lat + 0.001, 139.0, day: 2)) }   // 1 セルだけ 2 枚
        }
        let unlimited = PhotoMapClustering.pins(candidates: photos, region: region(36.5, 139.0, 4),
                                                columns: 100, pinLimit: 1_000, minimumSeparation: 0)
        #expect(unlimited.count == 60, "fixture が 1 地点 1 セルになっていない: \(unlimited.count)")

        let pins = PhotoMapClustering.pins(candidates: photos, region: region(36.5, 139.0, 4),
                                           columns: 100, pinLimit: 20, minimumSeparation: 0)
        #expect(pins.count == 20, "上限が効いていない: \(pins.count)")
        #expect(pins.contains { $0.count == 2 }, "件数の多いセルが落とされている")
    }

    /// ⚠️ 実フィードバック「ピンが密集しすぎ」。グリッドだけでは、隣り合うセルの写真が
    /// それぞれ境界側に寄っているとピンが接触する。**画面に正規化した距離**で近すぎるものを
    /// 大きいほうへ吸収する。吸収であって間引きではない＝写真は 1 枚も落ちない。
    @Test("近すぎるピンは吸収される（間隔が空き、写真は落ちない）")
    func nearbyPinsAreAbsorbed() {
        // 0.05° 間隔＝4° の画面では 1.25% しか離れておらず、確実に重なる配置。
        let photos = (0..<40).map { candidate(35.0 + Double($0) * 0.05, 139.0, day: $0 + 1) }
        let r = region(36.0, 139.0, 4)
        let pins = PhotoMapClustering.pins(candidates: photos, region: r, columns: 100,
                                           minimumSeparation: 0.12)

        #expect(pins.count < 12, "吸収されていない（密集したまま）: \(pins.count)")
        #expect(pins.reduce(0) { $0 + $1.count } == 40, "吸収で写真が落ちた")
        // 残ったピンどうしは、画面比で最小間隔以上離れている。
        for a in pins {
            for b in pins where a.id != b.id {
                let dx = (a.longitude - b.longitude) / r.longitudeDelta
                let dy = (a.latitude - b.latitude) / r.latitudeDelta
                #expect((dx * dx + dy * dy).squareRoot() >= 0.12 - 0.0001,
                        "ピンが近すぎる: \(a.id) と \(b.id)")
            }
        }
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

    /// ⚠️ ピンのサムネはクラウド写真だと表示用サムネと同じ回線を通る。同じセルに端末写真が
    /// あるならそちらを代表にする（速く、通信も減る）。ここが崩れると地図を動かすたびに
    /// クラウドへ数十件の取得が飛ぶ。
    @Test("代表は端末内の写真を優先する（無ければクラウドの新しいもの）")
    func representativePrefersLocalPhotos() {
        let cloudNew = PlaceCandidate(latitude: 35.0, longitude: 139.0, isLocal: false,
                                      identifier: "/cloud/new.jpg",
                                      date: Date(timeIntervalSince1970: 900_000))
        let localOld = PlaceCandidate(latitude: 35.001, longitude: 139.001, isLocal: true,
                                      identifier: "L-old", date: Date(timeIntervalSince1970: 100_000))
        let mixed = PhotoMapClustering.pins(candidates: [cloudNew, localOld],
                                            region: region(35.0, 139.0, 1))
        #expect(mixed.first?.representative.identifier == "L-old",
                "クラウド写真が代表になっている（毎回ダウンロードが要る）")

        // 端末写真が無ければクラウドの新しいものが代表。
        let cloudOld = PlaceCandidate(latitude: 35.001, longitude: 139.001, isLocal: false,
                                      identifier: "/cloud/old.jpg",
                                      date: Date(timeIntervalSince1970: 100_000))
        let cloudOnly = PhotoMapClustering.pins(candidates: [cloudNew, cloudOld],
                                                region: region(35.0, 139.0, 1))
        #expect(cloudOnly.first?.representative.identifier == "/cloud/new.jpg")
    }

    /// ⚠️ 実フィードバック: 「全体が収まる範囲」だと開いた瞬間が日本全体になり、見たいものが無い。
    /// **いちばん写真の多い場所**に寄せる。国や都市をコードに書かず、データだけで決めること。
    @Test("初期位置は写真がいちばん多い場所（外れ値には引かれない）")
    func initialRegionCentersOnTheDensestPlace() {
        var photos: [PlaceCandidate] = []
        // 東京近郊に 30 枚（密集）。
        for i in 0..<30 { photos.append(candidate(35.68 + Double(i) * 0.0005, 139.76, day: i + 1)) }
        // 札幌に 4 枚、シドニーに 1 枚（外れ値）。
        for i in 0..<4 { photos.append(candidate(43.06, 141.35, day: i + 1)) }
        photos.append(candidate(-33.9, 151.2, day: 99))

        let region = PhotoMapClustering.initialRegion(of: photos)
        #expect(region != nil)
        #expect(abs((region?.centerLatitude ?? 0) - 35.687) < 0.02,
                "最多の場所に寄っていない: \(region?.centerLatitude ?? -1)")
        #expect((region?.latitudeDelta ?? 99) < 0.2,
                "引きすぎ（全体を収めようとしている）: \(region?.latitudeDelta ?? -1)")
    }

    /// 1 か所に 1 枚しか無いときでも、寄りすぎて破綻しないこと。
    @Test("写真が 1 枚でも最小幅の範囲を返す")
    func initialRegionForASinglePhoto() {
        let region = PhotoMapClustering.initialRegion(of: [candidate(35.0, 139.0)])
        #expect(region?.latitudeDelta ?? 0 >= 0.01)
        #expect(abs((region?.centerLatitude ?? 0) - 35.0) < 0.0001)
    }

    @Test("写真が無ければピンも範囲も無い")
    func emptyInput() {
        #expect(PhotoMapClustering.pins(candidates: [], region: .world).isEmpty)
        #expect(PhotoMapClustering.initialRegion(of: []) == nil)
    }
}
