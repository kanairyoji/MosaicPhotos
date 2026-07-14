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
    /// 端末写真の「お気に入り」か。グリッドのハート表示に使う。既定は false
    /// （クラウド等お気に入りの概念がないソースはそのまま false）。
    var isFavorite: Bool { get }
    /// お気に入りの**付け外しに対応**するか（＝端末写真）。フル画面のハートをトグル操作にできる。
    /// クラウド等は false でハートを出さない。既定は false。
    var supportsFavorite: Bool { get }
    /// クラウド（Dropbox 等）由来の写真か。フィルタ（ソース絞り込み）に使う。
    /// 既定は false（＝端末写真扱い）。クラウド系アイテムが true を返す。
    var isCloudSource: Bool { get }
}

public extension PhotoItem {
    var displayTitle: String? { nil }
    var coordinate: CLLocationCoordinate2D? { nil }
    var isFavorite: Bool { false }
    var supportsFavorite: Bool { false }
    var isCloudSource: Bool { false }
}
