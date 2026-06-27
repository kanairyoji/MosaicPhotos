import Foundation

/// `QuerySpec` のハード条件（日付/場所/人物/ソース/フラグ/向き/位置）を `EnrichedPhoto` 配列へ
/// 適用する純ロジック（テスト対象）。内容(content)条件はソフト＝採点側（`AIAlbumSearcher`）で扱うため
/// ここでは無視する。OR（節）はいずれかの節のハード条件をすべて満たせば通過。
public enum QueryEvaluator {

    /// 縦横判定のしきい値（aspect = 幅/高さ）。
    static let landscapeMin = 1.05
    static let portraitMax = 0.95

    public static func hardFilter(_ photos: [EnrichedPhoto], spec: QuerySpec,
                                  now: Date, calendar: Calendar = .current) -> [EnrichedPhoto] {
        var result = photos
        if spec.excludeScreenshots {
            result = result.filter { !$0.isScreenshot }
        }
        guard spec.hasHardConstraints else { return result }
        return result.filter { photo in
            spec.clauses.contains { clausePasses($0, photo, now: now, calendar: calendar) }
        }
    }

    /// 1 節のハード条件をすべて満たすか（ソフト条件はスキップ）。ハード条件が無い節は通過。
    static func clausePasses(_ clause: QueryClause, _ photo: EnrichedPhoto,
                             now: Date, calendar: Calendar) -> Bool {
        for cond in clause.conditions {
            if let pass = hardPasses(cond, photo, now: now, calendar: calendar), !pass {
                return false
            }
        }
        return true
    }

    /// 条件の真偽。ソフト（content / not(content)）は nil（＝ハード評価では無視）。
    static func hardPasses(_ cond: Condition, _ p: EnrichedPhoto,
                           now: Date, calendar: Calendar) -> Bool? {
        switch cond {
        case .content:
            return nil
        case .not(let inner):
            guard let v = hardPasses(inner, p, now: now, calendar: calendar) else { return nil }
            return !v
        case .date(let range):
            let (start, end) = range.resolved(now: now, calendar: calendar)
            guard let d = p.captureDate else { return false }
            return d >= start && d <= end
        case .place(let terms):
            let hay = [p.placeName, p.country].compactMap { $0?.lowercased() }
            let t = terms.map { $0.lowercased() }
            return t.contains { term in hay.contains { $0.contains(term) } }
        case .people(let terms):
            let names = p.people.map { $0.lowercased() }
            let t = terms.map { $0.lowercased() }
            return t.contains { term in names.contains { $0.contains(term) } }
        case .peopleAtLeast(let n):
            return p.people.count >= n
        case .source(let src):
            switch src {
            case .local: return p.isLocal
            case .cloud: return !p.isLocal
            case .any: return true
            }
        case .favorite:
            return p.isFavorite
        case .screenshot:
            return p.isScreenshot
        case .hasLocation:
            return p.latitude != nil && p.longitude != nil
        case .orientation(let o):
            guard let a = p.aspect else { return false }
            switch o {
            case .landscape: return a >= landscapeMin
            case .portrait:  return a <= portraitMax
            case .square:    return a > portraitMax && a < landscapeMin
            }
        }
    }
}
