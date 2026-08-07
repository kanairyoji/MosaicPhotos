import CoreLocation
import Foundation
import PhotoSourceKit

/// 台帳の地名（placeName/country）を更新する 1 件分の差分。
public struct PlaceUpdate: Sendable, Equatable {
    public let refKey: String
    public let placeName: String?
    public let country: String?

    public init(refKey: String, placeName: String?, country: String?) {
        self.refKey = refKey
        self.placeName = placeName
        self.country = country
    }
}

/// 地名の高精度化（Apple 補正）を「実際に写真があるグリッドセル」に向けるための純ロジック（テスト対象）。
///
/// 旧実装はトリップ代表座標（＝メンバー座標の単純平均）だけを補正していたが、複数都市をまたぐ旅行では
/// 平均が「誰も撮っていない地点」になり得るうえ、補正結果が写真の属する別セルへ届かなかった。
/// 本ロジックは (1) 台帳の座標付き写真から使用中セルを枚数の多い順に列挙し（補正の優先順）、
/// (2) 補正後の resolver キャッシュと台帳を突き合わせて更新すべき差分を返す（伝播）。
public enum PlaceRefinement {

    /// 座標付き写真をグリッドセルへ集約し、**枚数の多い順**に各セルの重心座標を返す。
    /// 重心はセル内の点の平均なのでセル境界からはみ出さない（同じグリッドキーに丸まる）。
    public static func cellCentroids(photos: [EnrichedPhoto],
                                     step: Double = GeoGridKey.defaultStep) -> [CLLocationCoordinate2D] {
        var sumsByCell: [String: (latSum: Double, lonSum: Double, count: Int)] = [:]
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude,
                  lat.isFinite, lon.isFinite else { continue }
            let key = GeoGridKey.key(latitude: lat, longitude: lon, step: step)
            var s = sumsByCell[key] ?? (0, 0, 0)
            s.latSum += lat; s.lonSum += lon; s.count += 1
            sumsByCell[key] = s
        }
        return sumsByCell.values
            .sorted { $0.count > $1.count }
            .map { CLLocationCoordinate2D(latitude: $0.latSum / Double($0.count),
                                          longitude: $0.lonSum / Double($0.count)) }
    }

    /// resolver キャッシュの現在値と台帳を突き合わせ、地名が変わった写真の更新差分を返す。
    /// - `cache` のキーは言語接頭辞つき（`keyPrefix` ＝ "ja:"/"en:"）。
    /// - キャッシュに無いセル（未解決）は**触らない**（nil で上書きしない）。
    /// - 地名の選び方は `PlaceNameResolver.cityName` と同一（locality → admin → country）。
    public static func ledgerChanges(photos: [EnrichedPhoto],
                                     cache: [String: PlaceComponents],
                                     keyPrefix: String,
                                     step: Double = GeoGridKey.defaultStep) -> [PlaceUpdate] {
        var changes: [PlaceUpdate] = []
        for photo in photos {
            guard let lat = photo.latitude, let lon = photo.longitude,
                  lat.isFinite, lon.isFinite else { continue }
            let key = keyPrefix + GeoGridKey.key(latitude: lat, longitude: lon, step: step)
            guard let comp = cache[key], !comp.isEmpty else { continue }
            let newPlace = comp.locality ?? comp.administrativeArea ?? comp.country
            let newCountry = comp.country
            if newPlace != photo.placeName || newCountry != photo.country {
                changes.append(PlaceUpdate(refKey: photo.id, placeName: newPlace, country: newCountry))
            }
        }
        return changes
    }
}
