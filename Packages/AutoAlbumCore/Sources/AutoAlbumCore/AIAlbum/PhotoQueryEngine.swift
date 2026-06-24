import Foundation

/// `AIAlbumQuery` を `EnrichedPhoto` 配列への述語として適用する純ロジック（テスト対象）。
/// SwiftData の `#Predicate` でも書けるが、地名/人物の部分一致や相対日付解決を含むため、
/// メモリ上のフィルタとして実装する（付加情報は端末規模なら十分高速）。
public enum PhotoQueryEngine {

    public static func filter(_ photos: [EnrichedPhoto], with query: AIAlbumQuery,
                              now: Date, calendar: Calendar = .current) -> [EnrichedPhoto] {
        var result = photos

        if query.excludeScreenshots { result = result.filter { !$0.isScreenshot } }
        if query.favoritesOnly { result = result.filter(\.isFavorite) }

        switch query.source {
        case .local: result = result.filter(\.isLocal)
        case .cloud: result = result.filter { !$0.isLocal }
        case .any: break
        }

        if let range = query.dateRange {
            let (start, end) = range.resolved(now: now, calendar: calendar)
            result = result.filter { photo in
                guard let date = photo.captureDate else { return false }
                return date >= start && date <= end
            }
        }

        if !query.placeTerms.isEmpty {
            let terms = query.placeTerms.map { $0.lowercased() }
            result = result.filter { photo in
                let haystack = [photo.placeName, photo.country].compactMap { $0?.lowercased() }
                return terms.contains { term in haystack.contains { $0.contains(term) } }
            }
        }

        if !query.peopleTerms.isEmpty {
            let terms = query.peopleTerms.map { $0.lowercased() }
            result = result.filter { photo in
                let names = photo.people.map { $0.lowercased() }
                return terms.contains { term in names.contains { $0.contains(term) } }
            }
        }

        // 内容語（keywords）は CLIP の意味検索（AIAlbumSearcher）で扱う。ここでは構造化条件のみ
        // （ハードコードの語彙辞書・タグ照合を持たない）。
        return result
    }
}
