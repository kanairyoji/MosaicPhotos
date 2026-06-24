import Foundation
import SwiftData

/// 生成済みアルバムの永続レコード（仮想アルバム。Photos.app は変更しない）。
/// メンバー/カバーはエンコード済み `PhotoRef`（ローカル/クラウド混在可）。
/// `id` は戦略 ID＋日付範囲から決まる安定キーで、再生成時は丸ごと置き換える。
@Model
final class GeneratedAlbum {
    @Attribute(.unique) var id: String
    var strategyID: String
    var title: String
    var placeName: String?
    var places: [String]
    var country: String?
    var people: [String]
    var startDate: Date
    var endDate: Date
    var coverRef: String?
    var memberRefs: [String]
    var photoCount: Int
    var representativeDate: Date
    var latitude: Double?
    var longitude: Double?
    /// AI アルバムの元の検索条件（編集用）。
    var criteria: String?
    var createdAt: Date

    init(id: String, strategyID: String, title: String, placeName: String?, places: [String],
         country: String?, people: [String], startDate: Date, endDate: Date, coverRef: String?,
         memberRefs: [String], photoCount: Int, representativeDate: Date,
         latitude: Double?, longitude: Double?, criteria: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.strategyID = strategyID
        self.title = title
        self.placeName = placeName
        self.places = places
        self.country = country
        self.people = people
        self.startDate = startDate
        self.endDate = endDate
        self.coverRef = coverRef
        self.memberRefs = memberRefs
        self.photoCount = photoCount
        self.representativeDate = representativeDate
        self.latitude = latitude
        self.longitude = longitude
        self.criteria = criteria
        self.createdAt = createdAt
    }

    var asInfo: AutoAlbumInfo {
        AutoAlbumInfo(id: id, strategyID: strategyID, title: title, placeName: placeName, places: places,
                      country: country, people: people, startDate: startDate, endDate: endDate,
                      coverRef: coverRef, memberRefs: memberRefs, photoCount: photoCount,
                      representativeDate: representativeDate, latitude: latitude, longitude: longitude,
                      criteria: criteria)
    }
}
