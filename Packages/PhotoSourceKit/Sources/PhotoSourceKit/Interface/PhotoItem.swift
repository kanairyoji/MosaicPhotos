import CoreLocation
import Foundation

/// A single photo that can be displayed from any source.
public protocol PhotoItem: Identifiable, Hashable, Sendable {
    var captureDate: Date? { get }
    /// Short title shown in the navigation bar of the detail page.
    /// Return `nil` to fall back to the formatted `captureDate`.
    var displayTitle: String? { get }
    /// 撮影地の座標（取得できない場合は nil）。詳細画面の地図表示・場所グルーピングに使う。
    var coordinate: CLLocationCoordinate2D? { get }
}

public extension PhotoItem {
    var displayTitle: String? { nil }
    var coordinate: CLLocationCoordinate2D? { nil }
}
