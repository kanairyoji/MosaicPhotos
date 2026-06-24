import Foundation
import PhotoSourceKit

/// 生成済みアルバムの表示用値オブジェクト（@Model を UI/actor 外へ漏らさない Sendable 値）。
/// Codable にしておき、将来 Dropbox への付加情報コピー（JSON 化）にも使える。
public struct AutoAlbumInfo: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let strategyID: String
    public let title: String
    public let placeName: String?
    public let places: [String]
    public let country: String?
    public let people: [String]
    public let startDate: Date
    public let endDate: Date
    public let coverRef: String?
    public let memberRefs: [String]
    public let photoCount: Int
    public let representativeDate: Date
    public let latitude: Double?
    public let longitude: Double?
    /// AI アルバムの元の検索条件（自然文）。再設定（編集）時に呼び戻すために保持。他種別は nil。
    public let criteria: String?

    public init(id: String, strategyID: String, title: String, placeName: String?, places: [String],
                country: String?, people: [String], startDate: Date, endDate: Date, coverRef: String?,
                memberRefs: [String], photoCount: Int, representativeDate: Date,
                latitude: Double?, longitude: Double?, criteria: String? = nil) {
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
    }

    /// メンバーをローカル localIdentifier 群とクラウド path 群に分解する（表示時に使用）。
    public var localIdentifiers: [String] { memberRefs.compactMap { PhotoRef.decode($0)?.localIdentifier } }
    public var cloudPaths: [String] { memberRefs.compactMap { PhotoRef.decode($0)?.cloudPath } }
    public var coverPhotoRef: PhotoRef? { coverRef.flatMap(PhotoRef.decode) }

    /// 訪問地ラベル（最大2件を " & " 連結、超過は "+N"）。
    public var placesLabel: String {
        guard !places.isEmpty else { return placeName ?? "Trip" }
        let head = places.prefix(2).joined(separator: " & ")
        return places.count > 2 ? "\(head) +\(places.count - 2)" : head
    }

    /// 泊数（UTC 基準の日数差）。
    public var nights: Int { max(0, dayBucket(endDate) - dayBucket(startDate)) }

    /// 期間ラベル（"Day trip" / "3 days"）。
    public var durationLabel: String { nights == 0 ? "Day trip" : "\(nights + 1) days" }
}

/// 下書きから安定 ID とタイトルを組み立てるヘルパー。
public enum AutoAlbumComposer {
    /// 戦略 ID と日付範囲から決定的な安定 ID（再生成時の upsert キー）。
    public static func stableID(_ draft: GeneratedAlbumDraft) -> String {
        "\(draft.strategyID):\(Int(draft.startDate.timeIntervalSince1970))-\(Int(draft.endDate.timeIntervalSince1970))"
    }

    /// 「訪問地（国）· 日付範囲」のタイトル（日付は YYYY-MM-DD で統一）。
    public static func title(_ draft: GeneratedAlbumDraft) -> String {
        var label = draft.places.isEmpty
            ? (draft.placeName ?? "Trip")
            : draft.places.prefix(2).joined(separator: " & ")
        if draft.places.count > 2 { label += " +\(draft.places.count - 2)" }
        if let country = draft.country, !country.isEmpty { label += ", \(country)" }
        return "\(label) · \(DisplayDate.range(draft.startDate, draft.endDate))"
    }
}
