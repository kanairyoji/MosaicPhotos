import Foundation
import SwiftData

/// Tracks disk-cache usage for a single binary cache entry (thumbnail or full
/// image), used to enforce per-kind capacity limits via LRU eviction.
///
/// `key` is formatted as `"<kind>:<path>"` (e.g. `"thumbnail:/photo.jpg"`),
/// guaranteeing uniqueness across both kinds while keeping a simple primary key.
@Model
final class CacheUsageEntry {
    @Attribute(.unique) var key: String
    var kind: String
    var byteSize: Int
    var lastAccessedAt: Date

    init(key: String, kind: CacheKind, byteSize: Int, lastAccessedAt: Date = Date()) {
        self.key = key
        self.kind = kind.rawValue
        self.byteSize = byteSize
        self.lastAccessedAt = lastAccessedAt
    }

    /// Binary cache category. Stored as a raw `String` on the model (SwiftData
    /// `@Model` stored properties must be simple value types), but exposed via
    /// this enum for type-safe construction and comparison.
    enum CacheKind: String {
        case thumbnail
        case fullImage

        static func parse(_ raw: String) -> CacheKind? {
            CacheKind(rawValue: raw)
        }
    }

    static func makeKey(kind: CacheKind, path: String) -> String {
        "\(kind.rawValue):\(path)"
    }
}
