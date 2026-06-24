import Foundation
import SwiftData

/// Cached metadata for a single Dropbox file entry.
///
/// `path` (Dropbox `path_lower`) is the primary key — paths are globally unique
/// within an account. `contentHash` enables cheap change detection: when the
/// hash returned by Dropbox differs from the cached value, the cached binaries
/// (thumbnail / full image) are invalidated and re-fetched on next access.
@Model
final class CachedDropboxItem {
    @Attribute(.unique) var path: String
    var name: String
    var contentHash: String?
    var captureDate: Date?
    /// 撮影地の緯度・経度（`media_info` から取得。未取得時は nil）。追加プロパティは軽量マイグレーション。
    var latitude: Double?
    var longitude: Double?
    var cachedAt: Date

    init(
        path: String,
        name: String,
        contentHash: String? = nil,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        cachedAt: Date = Date()
    ) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.cachedAt = cachedAt
    }
}
