import CoreLocation
import Foundation

/// 座標を粗いグリッドに丸めた文字列キーを生成する。逆ジオコーディングのキャッシュ／場所
/// グルーピングで共有し、グリッド粒度の定義を一箇所に集約する。
public enum GeoGridKey {
    /// 既定の粒度（度）。~2km。市区町村単位のグルーピングに十分で、ジオコード回数を抑える。
    public static let defaultStep = 0.02

    public static func key(latitude: Double, longitude: Double, step: Double = defaultStep) -> String {
        let lat = (latitude / step).rounded() * step
        let lon = (longitude / step).rounded() * step
        return String(format: "%.3f,%.3f", lat, lon)
    }

    public static func key(_ coordinate: CLLocationCoordinate2D, step: Double = defaultStep) -> String {
        key(latitude: coordinate.latitude, longitude: coordinate.longitude, step: step)
    }
}
