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

    // ⚠️ OR 対応の GeneratedSpec 経路は一旦無効化（FM が「子供」等を peopleAtLeast/位置などの
    //    ハード条件にしてしまい、People インデックス等を満たさない写真を全除外＝空になる回帰のため）。
    //    当面は実績ある flat 解釈（interpret）→ asQuerySpec（既定 interpretSpec）に委ねる。
    //    OR/多ファセットは、ハード条件のサニタイズ（データで満たせない条件の抑制）＋実機検証の上で再投入する。

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
#endif
