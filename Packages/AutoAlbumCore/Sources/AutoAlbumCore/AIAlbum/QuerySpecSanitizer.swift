import Foundation

/// LLM（オンデバイス Foundation Models）が出した `QuerySpec` の**防御的サニタイズ**（純ロジック・テスト対象）。
///
/// 小型のオンデバイス LLM は guided generation でも構造化出力が乱れる（実障害2件）：
/// - v1: プロンプトの例語（child, beach…）を contentInclude にオウム返し・place にカタログ全 37 地名を丸写し
/// - v2: プレースホルダ語 "any" を place/people に文字列として出力・**除外対象（people）を include にも**入れる
///   → include と exclude が正面衝突し、対比採点で全滅（アルバム 0 件）
///
/// プロンプト改善だけでは再発するため、解釈直後に必ず本サニタイザを通す。
enum QuerySpecSanitizer {

    /// プレースホルダ・汎用語（値ではなく「指定なし」を表す語）。place/people/content から除去する。
    private static let placeholders: Set<String> = ["any", "none", "all", "unknown", "n/a", "na", "-", ""]

    /// place/people の項数がこれを超えたら「カタログ丸写し」とみなし条件ごと捨てる
    /// （ユーザーが 1 つの検索文で 6 箇所以上を明示指定することは実際にはない）。
    private static let catalogDumpThreshold = 5

    static func sanitize(_ spec: QuerySpec) -> QuerySpec {
        var out = spec
        out.clauses = spec.clauses.compactMap { sanitizeClause($0) }
        return out
    }

    private static func sanitizeClause(_ clause: QueryClause) -> QueryClause? {
        // まず exclude 集合を確定（include との衝突解消に使う。除外＝ユーザーの明示否定を優先）。
        var excludeTerms = Set<String>()
        for cond in clause.conditions {
            if case .not(.content(let terms)) = cond {
                excludeTerms.formUnion(cleanTerms(terms).map { $0.lowercased() })
            }
        }

        var conds: [Condition] = []
        for cond in clause.conditions {
            switch cond {
            case .place(let terms):
                let cleaned = cleanTerms(terms)
                guard !cleaned.isEmpty, cleaned.count <= catalogDumpThreshold else { continue }
                conds.append(.place(cleaned))
            case .people(let terms):
                let cleaned = cleanTerms(terms)
                guard !cleaned.isEmpty, cleaned.count <= catalogDumpThreshold else { continue }
                conds.append(.people(cleaned))
            case .content(let terms):
                // include から除外語を引く（"people" を含めつつ not(people) は矛盾＝除外が勝つ）。
                let cleaned = cleanTerms(terms).filter { !excludeTerms.contains($0.lowercased()) }
                guard !cleaned.isEmpty else { continue }
                conds.append(.content(cleaned))
            case .not(.content(let terms)):
                let cleaned = cleanTerms(terms)
                guard !cleaned.isEmpty else { continue }
                conds.append(.not(.content(cleaned)))
            default:
                conds.append(cond)
            }
        }
        // 全条件が消えた節は捨てる（呼び出し側で clauses が空＝純意味検索として扱われる）。
        return conds.isEmpty ? nil : QueryClause(conds)
    }

    private static func cleanTerms(_ terms: [String]) -> [String] {
        terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !placeholders.contains($0.lowercased()) }
    }
}
