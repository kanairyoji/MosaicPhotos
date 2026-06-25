import Foundation
import SwiftData

/// 1 写真分の付加情報（時間・場所・人物・各種シグナル・重複排除キー）。アルバム生成の入力であり、
/// 将来 Dropbox へコピーする「付加情報DB」の中核。
@Model
final class PhotoEnrichment {
    /// エンコード済み PhotoRef（"L-…"/"C-…"）。一意キー。
    @Attribute(.unique) var refKey: String
    var kind: String            // "local" / "cloud"
    var localIdentifier: String?
    var cloudPath: String?
    var captureDate: Date?
    var latitude: Double?
    var longitude: Double?
    var placeName: String?
    var country: String?
    var linkKey: String?
    var contentHash: String?
    var isScreenshot: Bool
    var isFavorite: Bool
    var aspect: Double?
    var people: [String]
    /// CLIP 埋め込みを試行済みか（取得不可でも true。未処理写真の抽出と無限ループ防止に使う）。
    var sceneTagged: Bool
    var clipVector: Data?
    var enrichedAt: Date

    init(refKey: String, kind: String, localIdentifier: String?, cloudPath: String?,
         captureDate: Date?, latitude: Double?, longitude: Double?, placeName: String?,
         country: String? = nil, linkKey: String? = nil, contentHash: String? = nil,
         isScreenshot: Bool = false, isFavorite: Bool = false, aspect: Double? = nil,
         people: [String] = [], sceneTagged: Bool = false,
         clipVector: Data? = nil, enrichedAt: Date = Date()) {
        self.refKey = refKey
        self.kind = kind
        self.localIdentifier = localIdentifier
        self.cloudPath = cloudPath
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.country = country
        self.linkKey = linkKey
        self.contentHash = contentHash
        self.isScreenshot = isScreenshot
        self.isFavorite = isFavorite
        self.aspect = aspect
        self.people = people
        self.sceneTagged = sceneTagged
        self.clipVector = clipVector
        self.enrichedAt = enrichedAt
    }

    var asEnrichedPhoto: EnrichedPhoto {
        EnrichedPhoto(id: refKey, captureDate: captureDate, latitude: latitude, longitude: longitude,
                      placeName: placeName, country: country, linkKey: linkKey, isScreenshot: isScreenshot,
                      isFavorite: isFavorite, aspect: aspect, people: people,
                      clipVector: clipVector)
    }

    /// clipVector を**読まない**軽量版。意味検索を伴わない用途（生成・重複排除・戦略・フォルダ）で使い、
    /// 67k×2KB の埋め込みをメモリへ載せない（実機のメモリ枯渇回避）。
    var asEnrichedPhotoLite: EnrichedPhoto {
        EnrichedPhoto(id: refKey, captureDate: captureDate, latitude: latitude, longitude: longitude,
                      placeName: placeName, country: country, linkKey: linkKey, isScreenshot: isScreenshot,
                      isFavorite: isFavorite, aspect: aspect, people: people,
                      clipVector: nil)
    }
}
