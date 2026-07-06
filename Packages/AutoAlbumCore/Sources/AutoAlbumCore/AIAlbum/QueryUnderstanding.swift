import Foundation

/// 自然文 → 構造化クエリ（`AIAlbumQuery`）の解釈器。LLM 実装とルールベース実装を差し替える DI シーム。
/// テストではスタブ、本番は端末 LLM（あれば）／ルールベース（フォールバック）。
public protocol QueryUnderstanding: Sendable {
    func interpret(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> AIAlbumQuery
    /// 合成可能な検索仕様（OR/NOT/複数ファセット）への解釈。既定はフラット解釈を単一節へ橋渡し。
    /// OR を出せる実装（Foundation Models）はこれを上書きする。
    func interpretSpec(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> QuerySpec
}

public extension QueryUnderstanding {
    func interpretSpec(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> QuerySpec {
        await interpret(text, catalog: catalog, now: now).asQuerySpec()
    }

    /// P2 Refine: 検索が空振りしたとき、クエリを言い換えた英語プローブ語（類義・下位概念）を生成する。
    /// 既定は空（ルールベース＝拡張なし）。FM 実装が上書きする。
    func expandProbes(_ text: String) async -> [String] { [] }
}

/// 既定の解釈器を返す。Apple Foundation Models（オンデバイス LLM）が使える端末ではそれを、
/// 使えなければルールベースを返す。完全オンデバイス・通信なし・API キー不要。
public func makeDefaultQueryUnderstanding() -> QueryUnderstanding {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, macOS 26.0, *), FoundationModelsQueryUnderstanding.isAvailable {
        return FoundationModelsQueryUnderstanding()
    }
    #endif
    return RuleBasedQueryUnderstanding()
}

/// Foundation Models が使えない端末向けの**最小限**フォールバック解釈器。
/// 言葉の辞書（内容語・相対日付の言い回し等）は持たず、以下だけを拾う：
/// - 西暦4桁（例 2021）→ 年指定
/// - お気に入りの明示
/// - 場所/人物はカタログ（実在する値）との部分一致で接地
/// 相対期間・内容語の自由な解釈は端末 LLM（FM）と CLIP に委ねる。
public struct RuleBasedQueryUnderstanding: QueryUnderstanding {
    public init() {}

    public func interpret(_ text: String, catalog: AIAlbumCatalog, now: Date) async -> AIAlbumQuery {
        let lower = text.lowercased()
        var query = AIAlbumQuery()

        // お気に入り（数少ない明示語のみ。語彙辞書ではない）。
        query.favoritesOnly = lower.contains("favorite") || lower.contains("favourite")
            || text.contains("お気に入り")

        // 相対・暦表現（ここN年・去年・過去Nヶ月・last N years 等）＋西暦4桁の保険。
        // FM 非対応端末でも日付が効くよう純パーサで解釈する。
        if let range = RelativeDateParser.parse(text, now: now) {
            query.dateRange = range
        }

        // 場所/人物はカタログ（実データ）との部分一致で接地。ハードコード語彙ではない。
        query.placeTerms = (catalog.places + catalog.countries).filter { term in
            !term.isEmpty && lower.contains(term.lowercased())
        }
        query.peopleTerms = catalog.people.filter { term in
            !term.isEmpty && lower.contains(term.lowercased())
        }

        query.title = Self.makeTitle(query: query, fallback: text, now: now)
        return query
    }

    // MARK: - Helpers

    static func makeTitle(query: AIAlbumQuery, fallback: String, now: Date) -> String {
        var parts: [String] = []
        if !query.placeTerms.isEmpty { parts.append(query.placeTerms.prefix(2).joined(separator: " & ")) }
        if !query.peopleTerms.isEmpty { parts.append(query.peopleTerms.prefix(2).joined(separator: " & ")) }
        if let range = query.dateRange, let label = dateLabel(range, now: now) { parts.append(label) }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }

    private static func dateLabel(_ range: AIAlbumDateRange, now: Date) -> String? {
        switch range.kind {
        case .year:       return range.value.map { "\($0)" }
        case .lastYears:  return range.value.map { "Last \($0)y" }
        case .lastMonths: return range.value.map { "Last \($0)mo" }
        case .lastDays:   return range.value.map { "Last \($0)d" }
        case .absolute:   return nil
        }
    }

    /// パターン内の最初のキャプチャ（無ければ全体）を Int で返す。
    static func firstInt(in text: String, pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let idx = m.numberOfRanges > 1 ? 1 : 0
        let r = m.range(at: idx)
        guard r.location != NSNotFound else { return nil }
        return Int(ns.substring(with: r))
    }
}
