import Foundation

/// 合成可能な検索条件（DNF: 節の OR・節内は AND・各条件は NOT 可）。
/// 既存のフラットな `AIAlbumQuery` を一般化し、日付/場所/人物/ソース/フラグ/向き/位置/内容(意味)を
/// 自由に組み合わせられるようにする。内容(`content`)だけ **ソフト**（CLIP コサインで採点）で、
/// それ以外は **ハード**（真偽でふるい分け）。`indirect` は `.not` の再帰のため。
public indirect enum Condition: Sendable, Codable, Equatable {
    case date(AIAlbumDateRange)
    case place([String])        // placeName / country に部分一致（語の OR）
    case people([String])       // 人物名に部分一致（OR）
    case peopleAtLeast(Int)     // 写っている人数 >= N
    case source(AISource)       // local / cloud
    case favorite               // お気に入り
    case screenshot             // スクリーンショットである
    case orientation(Orientation)
    case hasLocation            // 位置情報を持つ
    case content([String])      // 内容語（CLIP・語の OR）＝ソフト（採点）
    case not(Condition)         // 否定

    /// ハード条件か（content / not(content...) はソフト＝採点側で扱う）。
    public var isHard: Bool {
        switch self {
        case .content: return false
        case .not(let inner): return inner.isHard
        default: return true
        }
    }
}

public enum Orientation: String, Sendable, Codable, Equatable {
    case portrait, landscape, square
}

/// AND で結ぶ条件のまとまり（1 節）。
public struct QueryClause: Sendable, Codable, Equatable {
    public var conditions: [Condition]
    public init(_ conditions: [Condition] = []) { self.conditions = conditions }

    public var hardConditions: [Condition] { conditions.filter { $0.isHard } }
    /// この節のソフト（内容）条件を (含む語群, 除く語群) に分解する。
    public var contentTerms: (include: [String], exclude: [String]) {
        var inc: [String] = [], exc: [String] = []
        for c in conditions {
            switch c {
            case .content(let t): inc += t
            case .not(.content(let t)): exc += t
            default: break
            }
        }
        return (inc, exc)
    }
}

/// 検索仕様。`clauses` の OR（空なら全件＝ハード無条件）。`excludeScreenshots` は従来同様の既定フィルタ。
public struct QuerySpec: Sendable, Codable, Equatable {
    public var clauses: [QueryClause]
    public var title: String
    public var excludeScreenshots: Bool

    public init(clauses: [QueryClause] = [], title: String = "", excludeScreenshots: Bool = true) {
        self.clauses = clauses
        self.title = title
        self.excludeScreenshots = excludeScreenshots
    }

    /// ハード条件が一つでもあるか（無ければ全件がハード通過）。
    public var hasHardConstraints: Bool {
        clauses.contains { !$0.hardConditions.isEmpty }
    }

    /// 全節を通じた内容語（含む/除く）。採点の有無判定や semantic フォールバックに使う。
    public var allContentTerms: (include: [String], exclude: [String]) {
        var inc: [String] = [], exc: [String] = []
        for cl in clauses { let t = cl.contentTerms; inc += t.include; exc += t.exclude }
        return (inc, exc)
    }
    public var hasContent: Bool {
        let t = allContentTerms; return !t.include.isEmpty || !t.exclude.isEmpty
    }

    /// 人物条件（.people / .peopleAtLeast・.not 内含む）を含むか。
    /// 含むときだけ live 人物名マップ（PeopleEngine）を取得する（無関係なアルバムでは取得しない）。
    public var hasPeopleConditions: Bool {
        func containsPeople(_ cond: Condition) -> Bool {
            switch cond {
            case .people, .peopleAtLeast: return true
            case .not(let inner): return containsPeople(inner)
            default: return false
            }
        }
        return clauses.contains { $0.conditions.contains(where: containsPeople) }
    }
}

// MARK: - 既存 AIAlbumQuery からの橋渡し（後方互換）

public extension AIAlbumQuery {
    /// フラットな `AIAlbumQuery` を単一節（AND）の `QuerySpec` に写す。
    /// これにより既存の解釈器（フラット出力）も新評価器に載せられる。
    func asQuerySpec() -> QuerySpec {
        var conds: [Condition] = []
        if let range = dateRange { conds.append(.date(range)) }
        if !placeTerms.isEmpty { conds.append(.place(placeTerms)) }
        if !peopleTerms.isEmpty { conds.append(.people(peopleTerms)) }
        if favoritesOnly { conds.append(.favorite) }
        if source != .any { conds.append(.source(source)) }
        if !keywords.isEmpty { conds.append(.content(keywords)) }
        return QuerySpec(clauses: conds.isEmpty ? [] : [QueryClause(conds)],
                         title: title, excludeScreenshots: excludeScreenshots)
    }
}
