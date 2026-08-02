import Foundation

/// 位置情報付き写真候補（ソース非依存の値）。`isLocal` でローカル/Dropbox を区別する。
public struct PlaceCandidate: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let isLocal: Bool
    public let identifier: String   // localIdentifier または Dropbox path
    public let date: Date?

    public init(latitude: Double, longitude: Double, isLocal: Bool, identifier: String, date: Date?) {
        self.latitude = latitude
        self.longitude = longitude
        self.isLocal = isLocal
        self.identifier = identifier
        self.date = date
    }
}

/// 市区町村名でまとめた候補から `PlaceAlbumInfo` を構築する純ロジック（テスト対象）。
public enum PlaceGrouping {
    /// - Parameter byCity: 地名 → その地名の候補一覧。
    /// - Returns: **枚数の多い順**（同数なら代表日時＝最近の写真が新しい順）に並べた場所アルバム。
    public static func build(byCity: [String: [PlaceCandidate]]) -> [PlaceAlbumInfo] {
        byCity.compactMap { name, members -> PlaceAlbumInfo? in
            guard !members.isEmpty else { return nil }
            let sorted = members.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            let localIDs = sorted.filter { $0.isLocal }.map(\.identifier)
            let cloudPaths = sorted.filter { !$0.isLocal }.map(\.identifier)
            let newestLocal = sorted.last { $0.isLocal }?.identifier
            let newestCloud = sorted.last { !$0.isLocal }?.identifier
            return PlaceAlbumInfo(
                placeName: name,
                localIDs: localIDs,
                cloudPaths: cloudPaths,
                photoCount: sorted.count,
                coverLocalID: newestLocal,
                coverCloudPath: newestLocal == nil ? newestCloud : nil,
                representativeDate: sorted.compactMap(\.date).max() ?? .distantPast
            )
        }
        // 枚数の多い順。同数なら「最近の写真を含む方」（代表日時＝メンバー最大日時）が先。
        .sorted { a, b in
            a.photoCount != b.photoCount
                ? a.photoCount > b.photoCount
                : a.representativeDate > b.representativeDate
        }
    }
}
