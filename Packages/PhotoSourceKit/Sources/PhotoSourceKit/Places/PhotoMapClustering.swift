import CoreLocation
import Foundation

/// 地図上の 1 ピン（＝グリッドセル 1 つに畳んだ写真の束）。
public struct PhotoMapPin: Identifiable, Sendable, Hashable {
    /// グリッドキー（同じセルなら同じ id ＝ 再集約しても SwiftUI の差分が効く）。
    public let id: String
    /// セル内の写真の重心（セルの中心ではない＝写真が寄っている側に立つ）。
    public let latitude: Double
    public let longitude: Double
    public let count: Int
    /// 代表写真（サムネ表示・タップ時の初期位置に使う）。
    public let representative: PlaceCandidate
    /// このセルの写真（タップで開くときにそのまま渡す）。
    public let members: [PlaceCandidate]

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// ⚠️ 同一性は**セルのキーと件数**で決める。`members`（最大で数千件）まで比較/ハッシュすると、
    /// 画面更新のたびに写真の数だけ回ることになる（SwiftUI は差分判定で何度も呼ぶ）。
    public static func == (a: PhotoMapPin, b: PhotoMapPin) -> Bool {
        a.id == b.id && a.count == b.count
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(count)
    }

    public init(id: String, latitude: Double, longitude: Double, count: Int,
                representative: PlaceCandidate, members: [PlaceCandidate]) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.count = count
        self.representative = representative
        self.members = members
    }
}

/// 表示中の地図の範囲（MapKit 非依存の値＝純ロジックとして macOS でテストできる）。
public struct PhotoMapRegion: Sendable, Equatable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double,
                latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = max(latitudeDelta, 0.0001)
        self.longitudeDelta = max(longitudeDelta, 0.0001)
    }

    /// 世界全体（初期値・写真が 1 枚も無いとき用）。
    public static let world = PhotoMapRegion(centerLatitude: 0, centerLongitude: 0,
                                             latitudeDelta: 160, longitudeDelta: 320)
}

/// 座標付き写真を**ズームに応じたグリッド**で畳んで地図のピンにする（純ロジック）。
///
/// ⚠️ 設計の要点（CLAUDE.md 性能原則）: ライブラリは 86,000 枚規模で、そのすべてを
/// アノテーションにすると地図は描画も操作も破綻する。**可視範囲だけ**を対象に、
/// **ズームで決まる粒度**で畳み、**ピン数に上限**を置く——この 3 つで、写真が何枚あっても
/// 描画対象は数百に有界になる。集約そのものは O(可視枚数) の 1 パス。
///
/// SwiftUI の `Map` にクラスタリングは無い（`MKMapView` の `MKClusterAnnotation` は
/// 件数バッジ・代表写真を出しにくい）。自前で畳むほうが表示の自由度が高く、しかも
/// **純関数なのでテストできる**。
public enum PhotoMapClustering {

    /// 画面の横幅を何セルに割るか（大きいほど細かい）。
    /// ⚠️ 12 は**密集しすぎた**（実フィードバック）。画面幅 390pt に 12 列＝1 セル 32pt で、
    /// ピン（バッジ ~40pt）が確実に重なる。8 列＝約 49pt を出発点にし、最終的な間隔は
    /// 下の「画面上の最小間隔」で保証する。
    public static let defaultColumns: Double = 8
    /// 1 画面に置くピンの上限。超えたら件数の多い順に採る。
    public static let defaultPinLimit = 120
    /// **画面上の最小間隔**（画面幅に対する比）。グリッドだけでは「隣のセルの写真が
    /// セル境界の両側に寄っている」ときにピンが接触する。
    /// 0.14 ＝ 画面幅の 14%（390pt なら約 55pt）＝ バッジ（約 40pt）どうしが確実に離れる。
    /// この値で 1 画面のピンは最大でも約 50（1 / 0.14）² に収まる。
    public static let defaultMinimumSeparation: Double = 0.14

    /// ズーム（経度方向の幅）からグリッド粒度を決める。
    /// ⚠️ `GeoGridKey` は文字列キーを小数 3 桁で作るので、**それより細かい step は意味を持たない**
    /// （0.001 未満は同じキーに丸められる）。下限をそこに合わせる。
    public static func step(forLongitudeDelta delta: Double, columns: Double = defaultColumns) -> Double {
        let raw = delta / max(columns, 1)
        return min(max(raw, 0.001), 45)
    }

    /// 可視範囲の写真をセルへ畳んでピンにする。
    /// - Parameters:
    ///   - margin: 可視範囲をどれだけ広げて拾うか（1.0 = ぴったり）。少し広げると、
    ///     スクロール直後に端が空白にならない。
    public static func pins(candidates: [PlaceCandidate], region: PhotoMapRegion,
                            columns: Double = defaultColumns,
                            pinLimit: Int = defaultPinLimit,
                            minimumSeparation: Double = defaultMinimumSeparation,
                            margin: Double = 1.3) -> [PhotoMapPin] {
        guard !candidates.isEmpty else { return [] }
        let step = step(forLongitudeDelta: region.longitudeDelta, columns: columns)
        let latSpan = region.latitudeDelta * margin / 2
        let lonSpan = region.longitudeDelta * margin / 2
        let minLat = region.centerLatitude - latSpan, maxLat = region.centerLatitude + latSpan
        let minLon = region.centerLongitude - lonSpan, maxLon = region.centerLongitude + lonSpan

        var cells: [String: [PlaceCandidate]] = [:]
        for c in candidates {
            guard c.latitude >= minLat, c.latitude <= maxLat,
                  c.longitude >= minLon, c.longitude <= maxLon else { continue }
            cells[GeoGridKey.key(latitude: c.latitude, longitude: c.longitude, step: step),
                  default: []].append(c)
        }

        var pins = cells.compactMap { key, members -> PhotoMapPin? in
            guard !members.isEmpty else { return nil }
            let lat = members.reduce(0.0) { $0 + $1.latitude } / Double(members.count)
            let lon = members.reduce(0.0) { $0 + $1.longitude } / Double(members.count)
            // 代表は**新しい写真**（旅行の最新カットが出るほうが手がかりになる）。
            // ⚠️ ただし**端末内の写真を優先**する。ピンのサムネはクラウド写真だと表示用サムネと
            // 同じ回線を通るので、同じセルに端末写真があるならそちらを出すほうが速く、通信も減る
            // （体感の差は「新しさ」より「出るか出ないか」のほうが大きい）。
            let newest = { (a: PlaceCandidate, b: PlaceCandidate) in
                (a.date ?? .distantPast) < (b.date ?? .distantPast)
            }
            let representative = members.filter(\.isLocal).max(by: newest)
                ?? members.max(by: newest)
            guard let representative else { return nil }
            return PhotoMapPin(id: key, latitude: lat, longitude: lon, count: members.count,
                               representative: representative, members: members)
        }
        // 件数の多い順（同数なら新しい順）。以降の「吸収」も上限も、この順で大きいほうを残す。
        pins.sort {
            ($0.count, $0.representative.date ?? .distantPast)
                > ($1.count, $1.representative.date ?? .distantPast)
        }
        pins = separated(pins, region: region, minimumSeparation: minimumSeparation)
        if pins.count > pinLimit { pins = Array(pins.prefix(pinLimit)) }
        return pins.sorted { $0.id < $1.id }
    }

    /// 画面上で近すぎるピンを**大きいほうへ吸収**する（写真は 1 枚も落とさない）。
    ///
    /// ⚠️ グリッドだけでは足りない: 隣り合うセルの写真がそれぞれ境界側に寄っていると、
    /// 重心どうしは 1 セルぶんも離れない。実際に「ピンが密集しすぎ」という結果になった。
    /// 距離は**画面に正規化した座標**（画面幅=1・画面高=1）で測る——緯度が高いほど経度 1 度が
    /// 詰まる問題も、画面比で測れば自動的に解ける。
    static func separated(_ pins: [PhotoMapPin], region: PhotoMapRegion,
                          minimumSeparation: Double) -> [PhotoMapPin] {
        guard minimumSeparation > 0, pins.count > 1 else { return pins }
        var kept: [PhotoMapPin] = []
        for pin in pins {                      // 件数の多い順に入る＝大きいピンが残る
            let x = (pin.longitude - region.centerLongitude) / region.longitudeDelta
            let y = (pin.latitude - region.centerLatitude) / region.latitudeDelta
            var nearest: (index: Int, distance: Double)?
            for (i, k) in kept.enumerated() {
                let kx = (k.longitude - region.centerLongitude) / region.longitudeDelta
                let ky = (k.latitude - region.centerLatitude) / region.latitudeDelta
                let d = ((x - kx) * (x - kx) + (y - ky) * (y - ky)).squareRoot()
                if d < minimumSeparation, nearest == nil || d < nearest!.distance {
                    nearest = (i, d)
                }
            }
            if let nearest {
                kept[nearest.index] = absorb(kept[nearest.index], pin)
            } else {
                kept.append(pin)
            }
        }
        return kept
    }

    /// 近すぎたピンを吸収する（重心は件数で重み付け・代表は新しいほう）。
    private static func absorb(_ host: PhotoMapPin, _ other: PhotoMapPin) -> PhotoMapPin {
        let total = host.count + other.count
        let lat = (host.latitude * Double(host.count) + other.latitude * Double(other.count))
            / Double(total)
        let lon = (host.longitude * Double(host.count) + other.longitude * Double(other.count))
            / Double(total)
        // 吸収後の代表も「端末内優先 → 新しい方」（上と同じ規則）。
        let representative: PlaceCandidate
        if host.representative.isLocal != other.representative.isLocal {
            representative = host.representative.isLocal ? host.representative : other.representative
        } else {
            representative = (other.representative.date ?? .distantPast)
                > (host.representative.date ?? .distantPast) ? other.representative : host.representative
        }
        return PhotoMapPin(id: host.id, latitude: lat, longitude: lon, count: total,
                           representative: representative,
                           members: host.members + other.members)
    }

    /// **初期表示の範囲**＝「写真がいちばん多い場所」に寄せる（ADR-127 追補）。
    ///
    /// ⚠️ 実フィードバック: 全体が収まる範囲にすると「日本全体」のような引きになり、
    /// 開いた瞬間に見たいものが無い。⚠️ かといって国や都市を**コードに書かない**——
    /// どこに住んでいる人でも同じ規則で動く必要がある。データだけで決める:
    /// 1. 既定粒度（約 2km）で畳んで**最も枚数の多いセル**を選ぶ
    /// 2. そのセルの近傍（±`neighborhood` セル）にある写真の広がりを実際に測る
    /// 3. その広がりに余白を付けた範囲を返す（1 枚しか無ければ最小幅まで寄る）
    public static func initialRegion(of candidates: [PlaceCandidate],
                                     step: Double = GeoGridKey.defaultStep,
                                     neighborhood: Double = 3,
                                     padding: Double = 1.6,
                                     minimumSpan: Double = 0.01) -> PhotoMapRegion? {
        guard !candidates.isEmpty else { return nil }
        var cells: [String: [PlaceCandidate]] = [:]
        for c in candidates {
            cells[GeoGridKey.key(latitude: c.latitude, longitude: c.longitude, step: step),
                  default: []].append(c)
        }
        // 最多のセル（同数なら新しい写真があるほう）。
        guard let densest = cells.values.max(by: { a, b in
            let (ca, cb) = (a.count, b.count)
            if ca != cb { return ca < cb }
            let na = a.map { $0.date ?? .distantPast }.max() ?? .distantPast
            let nb = b.map { $0.date ?? .distantPast }.max() ?? .distantPast
            return na < nb
        }) else { return nil }

        let centerLat = densest.reduce(0.0) { $0 + $1.latitude } / Double(densest.count)
        let centerLon = densest.reduce(0.0) { $0 + $1.longitude } / Double(densest.count)
        // 近傍の写真まで含めて広がりを測る（同じ町がセル境界で切れていても、まとめて収める）。
        let reach = step * neighborhood
        let nearby = candidates.filter {
            abs($0.latitude - centerLat) <= reach && abs($0.longitude - centerLon) <= reach
        }
        let lats = nearby.map(\.latitude), lons = nearby.map(\.longitude)
        let latSpan = ((lats.max() ?? centerLat) - (lats.min() ?? centerLat)) * padding
        let lonSpan = ((lons.max() ?? centerLon) - (lons.min() ?? centerLon)) * padding
        return PhotoMapRegion(centerLatitude: centerLat, centerLongitude: centerLon,
                              latitudeDelta: max(latSpan, minimumSpan),
                              longitudeDelta: max(lonSpan, minimumSpan))
    }
}
