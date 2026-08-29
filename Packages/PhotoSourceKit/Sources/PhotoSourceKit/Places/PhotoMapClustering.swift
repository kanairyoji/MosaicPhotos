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
    public static let defaultColumns: Double = 12
    /// 1 画面に置くピンの上限。超えたら件数の多い順に採る。
    public static let defaultPinLimit = 120

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
            let representative = members.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            guard let representative else { return nil }
            return PhotoMapPin(id: key, latitude: lat, longitude: lon, count: members.count,
                               representative: representative, members: members)
        }
        // 上限を超えたら件数の多い順（同数なら新しい順）に採る。
        guard pins.count > pinLimit else { return pins.sorted { $0.id < $1.id } }
        pins.sort {
            ($0.count, $0.representative.date ?? .distantPast)
                > ($1.count, $1.representative.date ?? .distantPast)
        }
        return Array(pins.prefix(pinLimit)).sorted { $0.id < $1.id }
    }

    /// 写真全体が収まる範囲（初期表示のカメラ位置）。外れ値で世界地図にならないよう、
    /// **緯度経度の 5〜95 パーセンタイル**で囲う（1 枚の海外旅行で全体が引きに行かない）。
    public static func boundingRegion(of candidates: [PlaceCandidate],
                                      padding: Double = 1.4) -> PhotoMapRegion? {
        guard !candidates.isEmpty else { return nil }
        let lats = candidates.map(\.latitude).sorted()
        let lons = candidates.map(\.longitude).sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let idx = Int((Double(values.count - 1) * p).rounded())
            return values[min(max(idx, 0), values.count - 1)]
        }
        let minLat = percentile(lats, 0.05), maxLat = percentile(lats, 0.95)
        let minLon = percentile(lons, 0.05), maxLon = percentile(lons, 0.95)
        return PhotoMapRegion(centerLatitude: (minLat + maxLat) / 2,
                              centerLongitude: (minLon + maxLon) / 2,
                              latitudeDelta: max((maxLat - minLat) * padding, 0.01),
                              longitudeDelta: max((maxLon - minLon) * padding, 0.01))
    }
}
