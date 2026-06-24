import CoreLocation
import Foundation

public struct DropboxFileItem: Identifiable, Equatable, Hashable {
    public let path: String
    public let name: String
    /// Dropbox `content_hash` from `list_folder`. Used by `DropboxCacheStore` to
    /// detect remote changes and invalidate cached binaries cheaply.
    public let contentHash: String?
    /// 撮影日時。`media_info.time_taken` が取れればそれ、無ければ `client_modified`。
    public let captureDate: Date?
    /// 撮影地の緯度・経度（`list_folder` の `include_media_info` で取得。pending 時は nil）。
    public let latitude: Double?
    public let longitude: Double?

    public init(
        path: String,
        name: String,
        contentHash: String? = nil,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
    }

    public var id: String { path }

    /// 緯度・経度が揃っていれば座標を返す。
    public var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var nameWithoutExtension: String {
        (name as NSString).deletingPathExtension
    }
}
