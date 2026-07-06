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
        // ⚠️ LLM のセッション生成＋推論は Task.detached で確実にオフメイン化する
        //（呼び出し元は @MainActor のサービス。実測でメインを数秒塞いだ）。
        let instructions = Self.instructions(catalog: catalog, now: now)
        let generated: GeneratedAlbumQuery? = await Task.detached(priority: .userInitiated) {
            let session = LanguageModelSession(instructions: instructions)
            return try? await session.respond(to: text, generating: GeneratedAlbumQuery.self).content
        }.value
        if let generated { return Self.toQuery(generated, fallbackText: text) }
        // モデル未準備・コンテキスト超過などはルールベースで救済。
        return await RuleBasedQueryUnderstanding().interpret(text, catalog: catalog, now: now)
    }

    /// 合成可能仕様（OR/NOT/複数ファセット）への解釈。DNF（節の OR）を guided generation で出力する。
    /// ⚠️ 過去の回帰（「子供」等を peopleAtLeast 等のハード条件にしてデータを満たさず全滅）を踏まえ、
    ///    人物の有無や概念は **ハードにしない**（内容=ソフトで扱う）。日付は妥当性を検証する。
    ///    さらに `AIAlbumSearcher` 側の安全網（ハードで全滅したら内容のみへ緩和）が二重の保険になる。
    func interpretSpec(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> QuerySpec {
        // ⚠️ LLM のセッション生成＋推論は Task.detached で確実にオフメイン化する（上記と同様）。
        let instructions = Self.specInstructions(catalog: catalog, now: now)
        let generated: GeneratedSpec? = await Task.detached(priority: .userInitiated) {
            let session = LanguageModelSession(instructions: instructions)
            return try? await session.respond(to: text, generating: GeneratedSpec.self).content
        }.value
        if let generated {
            let spec = Self.toSpec(generated, fallbackText: text, now: now)
            // 念のため：節がすべて空（解釈不能）なら flat へフォールバック。
            return spec.clauses.isEmpty ? await interpret(text, catalog: catalog, now: now).asQuerySpec() : spec
        }
        return await RuleBasedQueryUnderstanding().interpretSpec(text, catalog: catalog, now: now)
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
        places: leave EMPTY unless the user's request names a specific place. If it does, use only \
        the matching name(s) from this catalog: [\(places)]. NEVER copy the whole catalog.
        Person names ONLY from this catalog: [\(people)]. Use a person name ONLY when the user names that specific person.
        dateKind is one of: none, year, lastYears, lastMonths, lastDays. dateValue is the 4-digit year for "year", or N for "lastX", else 0.
        source is one of: any, local, cloud. orientation is one of: any, portrait, landscape, square.
        favoritesOnly is true only for favorites.
        contentInclude: the visual subjects the user wants to SEE, translated to English single words \
        (a request about "風景" -> ["landscape"]). General subjects like "children" go here — NOT as a \
        person filter. Use ONLY words derived from the user's request; NEVER invent or copy sample words. Empty if none.
        contentExclude: visual content the user wants to AVOID, in English ("人が写っていない" / \
        "without people" -> ["people"]). Empty if none.
        Provide a concise title in the user's language.
        """
    }

    private static func toSpec(_ g: GeneratedSpec, fallbackText: String, now: Date) -> QuerySpec {
        var clauses: [QueryClause] = []
        for gc in g.clauses {
            var conds: [Condition] = []
            if !gc.places.isEmpty { conds.append(.place(gc.places)) }
            if !gc.people.isEmpty { conds.append(.people(gc.people)) }   // 具体的な人物名のみ（catalog 接地）
            if let range = sanitizedDate(kind: gc.dateKind, value: gc.dateValue, now: now) { conds.append(.date(range)) }
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
            if gc.favoritesOnly { conds.append(.favorite) }
            if !gc.contentInclude.isEmpty { conds.append(.content(gc.contentInclude)) }
            if !gc.contentExclude.isEmpty { conds.append(.not(.content(gc.contentExclude))) }
            if !conds.isEmpty { clauses.append(QueryClause(conds)) }
        }
        let title = g.title.isEmpty ? fallbackText : g.title
        return QuerySpec(clauses: clauses, title: title)
    }

    /// 日付の妥当性チェック（FM の暴発を抑える）。年は妥当範囲のみ、lastX は N>=1 のみ採用。
    private static func sanitizedDate(kind: String, value: Int, now: Date) -> AIAlbumDateRange? {
        let thisYear = Calendar.current.component(.year, from: now)
        switch kind.lowercased() {
        case "year":       return (1900...(thisYear + 1)).contains(value) ? .year(value) : nil
        case "lastyears":  return value >= 1 ? .lastYears(value) : nil
        case "lastmonths": return value >= 1 ? .lastMonths(value) : nil
        case "lastdays":   return value >= 1 ? .lastDays(value) : nil
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
/// ※ 人数(peopleAtLeast)・位置(hasLocation)は意図的に持たせない（データを満たさず全滅する回帰を防ぐ。
///   人物の有無や概念は contentInclude/contentExclude=ソフトで扱う）。
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
    @Guide(description: "Specific person names from the catalog only (only when the user names them). Empty otherwise.")
    var people: [String]
    @Guide(description: "Date filter kind: none, year, lastYears, lastMonths, or lastDays")
    var dateKind: String
    @Guide(description: "Year for 'year', or N for the 'lastX' kinds, otherwise 0")
    var dateValue: Int
    @Guide(description: "Photo source: any, local, or cloud")
    var source: String
    @Guide(description: "Orientation: any, portrait, landscape, or square")
    var orientation: String
    @Guide(description: "True only if the user wants favorites")
    var favoritesOnly: Bool
    @Guide(description: "Visual content words in English to match (e.g. child, children, beach). Empty if none.")
    var contentInclude: [String]
    @Guide(description: "Visual content words in English to exclude (e.g. people). Empty if none.")
    var contentExclude: [String]
}
#endif
