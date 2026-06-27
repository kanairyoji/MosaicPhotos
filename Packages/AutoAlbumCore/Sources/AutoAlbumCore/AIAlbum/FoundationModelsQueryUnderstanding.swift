#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// オンデバイス LLM（Apple Foundation Models / Apple Intelligence）による自然文 → 構造化クエリ解釈。
/// 通信なし・API キー不要。guided generation で型付き出力を強制し、カタログ語彙で接地する。
/// 利用不可・失敗時はルールベースへフォールバックする。
@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsQueryUnderstanding: QueryUnderstanding {

    static var isAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    func interpret(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> AIAlbumQuery {
        do {
            let session = LanguageModelSession(instructions: Self.instructions(catalog: catalog, now: now))
            let response = try await session.respond(to: text, generating: GeneratedAlbumQuery.self)
            return Self.toQuery(response.content, fallbackText: text)
        } catch {
            // モデル未準備・コンテキスト超過などはルールベースで救済。
            return await RuleBasedQueryUnderstanding().interpret(text, catalog: catalog, now: now)
        }
    }

    /// 合成可能仕様（OR/NOT/複数ファセット）への解釈。DNF（節の OR）を guided generation で出力する。
    func interpretSpec(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> QuerySpec {
        do {
            let session = LanguageModelSession(instructions: Self.specInstructions(catalog: catalog, now: now))
            let response = try await session.respond(to: text, generating: GeneratedSpec.self)
            return Self.toSpec(response.content, fallbackText: text)
        } catch {
            return await RuleBasedQueryUnderstanding().interpretSpec(text, catalog: catalog, now: now)
        }
    }

    private static func specInstructions(catalog: AIAlbumCatalog, now: Date) -> String {
        let places = catalog.places.prefix(40).joined(separator: ", ")
        let people = catalog.people.prefix(40).joined(separator: ", ")
        let today = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)
        return """
        Convert the user's request (any language) into a photo filter expressed as OR of groups (clauses).
        Today is \(today).
        Use EXACTLY ONE clause for normal requests; use multiple clauses ONLY for clear "A or B" alternatives.
        Within a clause all fields are ANDed. Leave fields empty / 0 / false / "any" / "none" when not mentioned.
        Place names ONLY from this catalog: [\(places)].
        Person names ONLY from this catalog: [\(people)].
        dateKind is one of: none, year, lastYears, lastMonths, lastDays. dateValue is the 4-digit year for "year", or N for "lastX", else 0.
        source is one of: any, local, cloud. orientation is one of: any, portrait, landscape, square.
        peopleAtLeast is the minimum number of people in the photo (0 if unspecified).
        hasLocation is true only if the user asks for photos that have a location.
        favoritesOnly is true only for favorites.
        contentInclude: visual content words IN ENGLISH to match (e.g. child, beach, dog, sunset). Empty if none.
        contentExclude: visual content IN ENGLISH to exclude (e.g. "without people" -> ["people"]). Empty if none.
        Provide a concise title in the user's language.
        """
    }

    private static func toSpec(_ g: GeneratedSpec, fallbackText: String) -> QuerySpec {
        var clauses: [QueryClause] = []
        for gc in g.clauses {
            var conds: [Condition] = []
            if !gc.places.isEmpty { conds.append(.place(gc.places)) }
            if !gc.people.isEmpty { conds.append(.people(gc.people)) }
            if gc.peopleAtLeast > 0 { conds.append(.peopleAtLeast(gc.peopleAtLeast)) }
            if let range = dateRange(kind: gc.dateKind, value: gc.dateValue) { conds.append(.date(range)) }
            switch gc.source.lowercased() {
            case "local": conds.append(.source(.local))
            case "cloud": conds.append(.source(.cloud))
            default: break
            }
            switch gc.orientation.lowercased() {
            case "portrait":  conds.append(.orientation(.portrait))
            case "landscape": conds.append(.orientation(.landscape))
            case "square":    conds.append(.orientation(.square))
            default: break
            }
            if gc.hasLocation { conds.append(.hasLocation) }
            if gc.favoritesOnly { conds.append(.favorite) }
            if !gc.contentInclude.isEmpty { conds.append(.content(gc.contentInclude)) }
            if !gc.contentExclude.isEmpty { conds.append(.not(.content(gc.contentExclude))) }
            if !conds.isEmpty { clauses.append(QueryClause(conds)) }
        }
        let title = g.title.isEmpty ? fallbackText : g.title
        return QuerySpec(clauses: clauses, title: title)
    }

    private static func dateRange(kind: String, value: Int) -> AIAlbumDateRange? {
        switch kind.lowercased() {
        case "year":       return .year(value)
        case "lastyears":  return .lastYears(max(1, value))
        case "lastmonths": return .lastMonths(max(1, value))
        case "lastdays":   return .lastDays(max(1, value))
        default:           return nil
        }
    }

    private static func instructions(catalog: AIAlbumCatalog, now: Date) -> String {
        let places = catalog.places.prefix(40).joined(separator: ", ")
        let people = catalog.people.prefix(40).joined(separator: ", ")
        let today = DateFormatter.localizedString(from: now, dateStyle: .short, timeStyle: .none)
        return """
        You convert a user's natural-language request (any language) into a photo album filter.
        Today is \(today).
        Choose place names ONLY from this catalog: [\(places)].
        Choose person names ONLY from this catalog: [\(people)].
        For dates set dateKind to one of: none, year, lastYears, lastMonths, lastDays.
        dateValue is the 4-digit year for "year", or N for the "lastX" kinds, else 0.
        favoritesOnly is true only if the user asks for favorites.
        Put visual content words (e.g. beach, food, dog, sunset, mountain) into keywords IN ENGLISH; empty if none.
        Provide a concise album title in the user's language.
        """
    }

    private static func toQuery(_ generated: GeneratedAlbumQuery, fallbackText: String) -> AIAlbumQuery {
        var query = AIAlbumQuery()
        query.title = generated.title.isEmpty ? fallbackText : generated.title
        query.placeTerms = generated.places
        query.peopleTerms = generated.people
        query.keywords = generated.keywords
        query.favoritesOnly = generated.favoritesOnly
        switch generated.dateKind.lowercased() {
        case "year":       query.dateRange = .year(generated.dateValue)
        case "lastyears":  query.dateRange = .lastYears(max(1, generated.dateValue))
        case "lastmonths": query.dateRange = .lastMonths(max(1, generated.dateValue))
        case "lastdays":   query.dateRange = .lastDays(max(1, generated.dateValue))
        default:           query.dateRange = nil
        }
        return query
    }
}

/// Foundation Models の guided generation 用の出力スキーマ。
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedAlbumQuery {
    @Guide(description: "A concise album title summarizing the request, in the user's language")
    var title: String
    @Guide(description: "Place names to match, taken only from the provided catalog. Empty if none.")
    var places: [String]
    @Guide(description: "Person names to match, taken only from the provided catalog. Empty if none.")
    var people: [String]
    @Guide(description: "Visual content words in English (e.g. beach, food, dog). Empty if none.")
    var keywords: [String]
    @Guide(description: "True only if the user explicitly wants favorite photos")
    var favoritesOnly: Bool
    @Guide(description: "Date filter kind: none, year, lastYears, lastMonths, or lastDays")
    var dateKind: String
    @Guide(description: "Year for 'year', or N for the 'lastX' kinds, otherwise 0")
    var dateValue: Int
}

/// 合成可能仕様（DNF）の guided generation スキーマ。clauses は OR、各 clause 内は AND。
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedSpec {
    @Guide(description: "A concise album title in the user's language")
    var title: String
    @Guide(description: "OR groups; usually exactly one. Each group's conditions are ANDed.")
    var clauses: [GeneratedClause]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedClause {
    @Guide(description: "Place names from the catalog only. Empty if none.")
    var places: [String]
    @Guide(description: "Person names from the catalog only. Empty if none.")
    var people: [String]
    @Guide(description: "Minimum number of people in the photo, 0 if unspecified")
    var peopleAtLeast: Int
    @Guide(description: "Date filter kind: none, year, lastYears, lastMonths, or lastDays")
    var dateKind: String
    @Guide(description: "Year for 'year', or N for the 'lastX' kinds, otherwise 0")
    var dateValue: Int
    @Guide(description: "Photo source: any, local, or cloud")
    var source: String
    @Guide(description: "Orientation: any, portrait, landscape, or square")
    var orientation: String
    @Guide(description: "True only if the user wants photos that have a location")
    var hasLocation: Bool
    @Guide(description: "True only if the user wants favorites")
    var favoritesOnly: Bool
    @Guide(description: "Visual content words in English to match (e.g. child, beach). Empty if none.")
    var contentInclude: [String]
    @Guide(description: "Visual content words in English to exclude (e.g. people). Empty if none.")
    var contentExclude: [String]
}
#endif
