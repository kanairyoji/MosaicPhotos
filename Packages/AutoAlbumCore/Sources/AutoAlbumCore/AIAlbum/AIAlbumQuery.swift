import Foundation

/// AI アルバムの戦略 ID（ユーザーが自然文から作る保存アルバム）。
public enum AIAlbumStrategy {
    public static let strategyID = "aiAlbum"
}

/// 検索ソース。
public enum AISource: String, Sendable, Codable {
    case any, local, cloud
}

/// AI アルバム作成の結果。UI 側でメッセージ分岐に使う。
/// 0 件でも保存する方針のため、作成は常に `.created`（条件文が空のときだけ `.empty`）。
public enum AIAlbumResult: Sendable {
    case created(AutoAlbumInfo)
    case empty
}

/// 自然文から解釈した構造化クエリ（DSL）。LLM/ルールベースの双方がこれを出力し、
/// `PhotoQueryEngine` が写真メタデータ（`EnrichedPhoto`）への述語に変換する。
public struct AIAlbumQuery: Sendable, Codable, Equatable {
    /// アルバム表示名（解釈結果。空ならアプリ側で原文を使う）。
    public var title: String
    /// 場所語（placeName / country に部分一致）。
    public var placeTerms: [String]
    /// 人物語（people に部分一致）。
    public var peopleTerms: [String]
    /// 内容語（将来の Vision タグ用。現状は未使用）。
    public var keywords: [String]
    public var dateRange: AIAlbumDateRange?
    public var favoritesOnly: Bool
    public var excludeScreenshots: Bool
    public var source: AISource

    public init(title: String = "", placeTerms: [String] = [], peopleTerms: [String] = [],
                keywords: [String] = [], dateRange: AIAlbumDateRange? = nil,
                favoritesOnly: Bool = false, excludeScreenshots: Bool = true, source: AISource = .any) {
        self.title = title
        self.placeTerms = placeTerms
        self.peopleTerms = peopleTerms
        self.keywords = keywords
        self.dateRange = dateRange
        self.favoritesOnly = favoritesOnly
        self.excludeScreenshots = excludeScreenshots
        self.source = source
    }

    /// ユーザー指定の構造化条件（場所/人物/期間/お気に入り/ソース）があるか。
    /// `excludeScreenshots` は既定 true の内部既定なので条件には数えない。
    public var hasStructuredConstraints: Bool {
        !placeTerms.isEmpty || !peopleTerms.isEmpty || dateRange != nil || favoritesOnly || source != .any
    }
}

/// 期間指定。相対（ここ数年など）はアプリ側で現在日時から確定する（LLM に日付演算させない）。
public struct AIAlbumDateRange: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case absolute, year, lastYears, lastMonths, lastDays
    }
    public var kind: Kind
    public var start: Date?   // absolute 用
    public var end: Date?     // absolute 用
    public var value: Int?    // year（西暦）/ lastN（N）用

    public init(kind: Kind, start: Date? = nil, end: Date? = nil, value: Int? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
    }

    public static func absolute(_ start: Date, _ end: Date) -> Self { .init(kind: .absolute, start: start, end: end) }
    public static func year(_ y: Int) -> Self { .init(kind: .year, value: y) }
    public static func lastYears(_ n: Int) -> Self { .init(kind: .lastYears, value: n) }
    public static func lastMonths(_ n: Int) -> Self { .init(kind: .lastMonths, value: n) }
    public static func lastDays(_ n: Int) -> Self { .init(kind: .lastDays, value: n) }

    /// 現在日時から具体的な期間 [start, end] に展開する。
    public func resolved(now: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        switch kind {
        case .absolute:
            return (start ?? .distantPast, end ?? now)
        case .year:
            let y = value ?? calendar.component(.year, from: now)
            let s = calendar.date(from: DateComponents(year: y, month: 1, day: 1)) ?? .distantPast
            let next = calendar.date(from: DateComponents(year: y + 1, month: 1, day: 1)) ?? now
            return (s, next.addingTimeInterval(-1))
        case .lastYears:
            return (calendar.date(byAdding: .year, value: -(value ?? 1), to: now) ?? .distantPast, now)
        case .lastMonths:
            return (calendar.date(byAdding: .month, value: -(value ?? 1), to: now) ?? .distantPast, now)
        case .lastDays:
            return (calendar.date(byAdding: .day, value: -(value ?? 1), to: now) ?? .distantPast, now)
        }
    }
}

/// ライブラリの検索語彙（LLM 接地・ルールベースの照合に使う）。`PhotoEnrichment` から集計。
public struct AIAlbumCatalog: Sendable, Equatable {
    public var places: [String]
    public var countries: [String]
    public var people: [String]
    public var earliest: Date?
    public var latest: Date?

    public init(places: [String], countries: [String], people: [String], earliest: Date?, latest: Date?) {
        self.places = places
        self.countries = countries
        self.people = people
        self.earliest = earliest
        self.latest = latest
    }

    /// 付加情報から語彙を構築する（頻度上位 maxTerms に丸める）。
    public static func build(from photos: [EnrichedPhoto], maxTerms: Int = 60) -> AIAlbumCatalog {
        let dates = photos.compactMap(\.captureDate)
        return AIAlbumCatalog(
            places: Array(rankedByFrequency(photos.compactMap(\.placeName)).prefix(maxTerms)),
            countries: Array(rankedByFrequency(photos.compactMap(\.country)).prefix(maxTerms)),
            people: Array(rankedByFrequency(photos.flatMap(\.people)).prefix(maxTerms)),
            earliest: dates.min(), latest: dates.max())
    }
}
