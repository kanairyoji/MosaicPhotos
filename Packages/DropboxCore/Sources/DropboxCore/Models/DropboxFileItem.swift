import CoreLocation
import Foundation
import MosaicSupport

public struct DropboxFileItem: Identifiable, Equatable, Hashable {
    public let path: String
    public let name: String
    /// Dropbox `content_hash` from `list_folder`. Used by `DropboxCacheStore` to
    /// detect remote changes and invalidate cached binaries cheaply.
    public let contentHash: String?
    /// 撮影日時。`media_info.time_taken` が取れればそれ、無ければ `client_modified`。
    /// 無意味な日付（EXIF 欠落・0 値・1970/1980 等）は init で nil＝日時不明に落とす。
    public let captureDate: Date?
    /// 撮影地の緯度・経度（`list_folder` の `include_media_info` で取得。pending 時は nil）。
    public let latitude: Double?
    public let longitude: Double?
    /// アプリ側お気に入り（Dropbox に favorite 概念は無いので、cloudPath 単位でアプリが管理する）。
    /// `DropboxPhotoStore` が items 構築時に永続集合から**刻印**する（既定 false）。
    public let isFavorite: Bool

    public init(
        path: String,
        name: String,
        contentHash: String? = nil,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        isFavorite: Bool = false
    ) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        // 生成点（同期パース・キャッシュ復元）でまとめてサニタイズする（入口で一度だけ）。
        self.captureDate = CaptureDate.meaningful(captureDate)
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
    }

    /// お気に入りだけ差し替えた複製（`DropboxPhotoStore` の刻印・トグルで使う）。
    public func withFavorite(_ favorite: Bool) -> DropboxFileItem {
        DropboxFileItem(path: path, name: name, contentHash: contentHash, captureDate: captureDate,
                        latitude: latitude, longitude: longitude, isFavorite: favorite)
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
