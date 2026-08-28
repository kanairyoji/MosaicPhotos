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
    /// **実体がどこにあるか**（フル画面の情報パネルに出す）。
    ///
    /// ⚠️ 「見えている写真が端末のものかクラウドのものか、クラウドならどのパスか」が分からないと、
    /// 「知らない写真が一覧に出る」類の不具合を実機で切り分けられない（実測: どのフォルダ由来かを
    /// 特定できず、ログからも判断できなかった）。表示できる形で必ず持たせる。
    var sourceLocation: PhotoSourceLocation { get }
}

/// 写真の実体の所在（端末 / クラウド＋パス）。
public struct PhotoSourceLocation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case local     // 端末の写真ライブラリ
        case cloud     // クラウド（Dropbox）
    }

    public let kind: Kind
    /// 端末なら localIdentifier、クラウドならフルパス。人が読んで場所を特定できる文字列。
    public let identifier: String

    public init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    /// クラウドのとき、パスの親フォルダ（「どのフォルダ由来か」が一目で分かるように）。
    public var folder: String? {
        guard kind == .cloud, let slash = identifier.lastIndex(of: "/") else { return nil }
        let parent = String(identifier[..<slash])
        return parent.isEmpty ? "/" : parent
    }
}

public extension PhotoItem {
    var displayTitle: String? { nil }
    var coordinate: CLLocationCoordinate2D? { nil }
    var isFavorite: Bool { false }
    var supportsFavorite: Bool { false }
    var isCloudSource: Bool { false }
    /// 既定は id をそのまま所在として出す（種別だけは `isCloudSource` から決まる）。
    /// パスを持つソースは必ず上書きすること。
    var sourceLocation: PhotoSourceLocation {
        PhotoSourceLocation(kind: isCloudSource ? .cloud : .local, identifier: "\(id)")
    }
}
