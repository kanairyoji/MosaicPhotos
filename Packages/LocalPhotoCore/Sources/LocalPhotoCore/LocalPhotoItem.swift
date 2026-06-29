import CoreLocation
import Foundation
import Photos
import PhotoSourceKit

public struct LocalPhotoItem: PhotoItem {
    public let asset: PHAsset

    public var id: String { asset.localIdentifier }
    public var captureDate: Date? { asset.creationDate }
    /// PHAsset の位置情報（OS が永続化済みのため随時取得可能）。
    public var coordinate: CLLocationCoordinate2D? { asset.location?.coordinate }
    /// 端末写真アプリの「お気に入り」フラグ（PHAsset から即時取得）。
    public var isFavorite: Bool { asset.isFavorite }
    /// 端末写真なのでお気に入りの付け外しに対応する。
    public var supportsFavorite: Bool { true }

    public static func == (lhs: LocalPhotoItem, rhs: LocalPhotoItem) -> Bool {
        lhs.asset.localIdentifier == rhs.asset.localIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(asset.localIdentifier)
    }
}

extension LocalPhotoItem: @unchecked Sendable {}
