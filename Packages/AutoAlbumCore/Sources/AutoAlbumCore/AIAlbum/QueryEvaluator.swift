import Foundation

/// `QuerySpec` のハード条件（日付/場所/人物/ソース/フラグ/向き/位置）を `EnrichedPhoto` 配列へ
/// 適用する純ロジック（テスト対象）。内容(content)条件はソフト＝採点側（`AIAlbumSearcher`）で扱うため
/// ここでは無視する。OR（節）はいずれかの節のハード条件をすべて満たせば通過。
public enum QueryEvaluator {

    /// 縦横判定のしきい値（aspect = 幅/高さ）。
    static let landscapeMin = 1.05
    static let portraitMax = 0.95

    /// - Parameter peopleByRefKey: 顔クラスタの**現在の**人物名（refKey → 名前・PeopleEngine 由来）。
    ///   人物名はリネーム/統合/クラスタ成長で変わるため、`EnrichedPhoto.people`（初回エンリッチ時の
    ///   焼き込み＝以後更新されない）でなく**検索時に live 照合**する（実障害: 後から命名した
    ///   「山田太郎」が焼き込みに反映されず「太郎と花子」が 0 件）。nil／未収載は焼き込みへフォールバック。
    public static func hardFilter(_ photos: [EnrichedPhoto], spec: QuerySpec,
                                  now: Date, calendar: Calendar = .current,
                                  peopleByRefKey: [String: [String]]? = nil) -> [EnrichedPhoto] {
        var result = photos
        if spec.excludeScreenshots {
            result = result.filter { !$0.isScreenshot }
        }
        guard spec.hasHardConstraints else { return result }
        return result.filter { photo in
            spec.clauses.contains {
                clausePasses($0, photo, now: now, calendar: calendar, peopleByRefKey: peopleByRefKey)
            }
        }
    }

    /// 1 節のハード条件をすべて満たすか（ソフト条件はスキップ）。ハード条件が無い節は通過。
    static func clausePasses(_ clause: QueryClause, _ photo: EnrichedPhoto,
                             now: Date, calendar: Calendar,
                             peopleByRefKey: [String: [String]]? = nil) -> Bool {
        for cond in clause.conditions {
            if let pass = hardPasses(cond, photo, now: now, calendar: calendar,
                                     peopleByRefKey: peopleByRefKey), !pass {
                return false
            }
        }
        return true
    }

    /// 写真の人物名（live マップ優先・未収載は焼き込みへフォールバック）。
    static func peopleNames(_ p: EnrichedPhoto, peopleByRefKey: [String: [String]]?) -> [String] {
        peopleByRefKey?[p.id] ?? p.people
    }

    /// 条件の真偽。ソフト（content / not(content)）は nil（＝ハード評価では無視）。
    static func hardPasses(_ cond: Condition, _ p: EnrichedPhoto,
                           now: Date, calendar: Calendar,
                           peopleByRefKey: [String: [String]]? = nil) -> Bool? {
        switch cond {
        case .content:
            return nil
        case .not(let inner):
            guard let v = hardPasses(inner, p, now: now, calendar: calendar,
                                     peopleByRefKey: peopleByRefKey) else { return nil }
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
            let names = peopleNames(p, peopleByRefKey: peopleByRefKey).map { $0.lowercased() }
            let t = terms.map { $0.lowercased() }
            return t.contains { term in names.contains { $0.contains(term) } }
        case .peopleAtLeast(let n):
            return peopleNames(p, peopleByRefKey: peopleByRefKey).count >= n
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
