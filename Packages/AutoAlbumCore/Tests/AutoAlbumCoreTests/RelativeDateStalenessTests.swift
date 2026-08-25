import Foundation
import Testing
@testable import AutoAlbumCore

/// ⚠️ 「直近 30 日」のような相対日付は、**写真が増えなくても範囲が動く**。
/// ドリフト検知は埋め込み枚数の差しか見ず、増分評価は既存メンバーを維持するため、
/// 期間外になった写真が残り続ける（レビュー指摘）。日付境界を越えたら再評価する。
@Suite("RelativeDateStaleness")
struct RelativeDateStalenessTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    private func spec(_ range: AIAlbumDateRange?) -> QuerySpec {
        guard let range else { return QuerySpec(clauses: [QueryClause([.content(["sea"])])]) }
        return QuerySpec(clauses: [QueryClause([.date(range), .content(["sea"])])])
    }

    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f.date(from: iso)!
    }

    @Test("相対日付は kind で見分ける（絶対日付は時間で動かない）")
    func identifiesTimeDependentRanges() {
        #expect(RelativeDateStaleness.isTimeDependent(.lastDays(30)))
        #expect(RelativeDateStaleness.isTimeDependent(.lastMonths(3)))
        #expect(RelativeDateStaleness.isTimeDependent(.lastYears(1)))
        #expect(RelativeDateStaleness.isTimeDependent(.year(2024)), "年をまたぐと「今年」の意味が変わる")
        #expect(!RelativeDateStaleness.isTimeDependent(
            .absolute(date("2025-01-01T00:00:00Z"), date("2025-02-01T00:00:00Z"))))
    }

    @Test("日付が変われば再評価する（写真が増えていなくても）")
    func refreshesAfterDayBoundary() {
        let yesterday = date("2026-08-24T23:50:00+09:00")
        let today = date("2026-08-25T00:10:00+09:00")
        #expect(RelativeDateStaleness.needsRefresh(spec: spec(.lastDays(30)),
                                                   lastEvaluatedAt: yesterday, now: today,
                                                   calendar: calendar),
                "期間外になった写真がアルバムに残り続ける")
    }

    @Test("同じ日のうちは再評価しない（無駄なフル評価を増やさない）")
    func doesNotRefreshWithinSameDay() {
        let morning = date("2026-08-25T08:00:00+09:00")
        let evening = date("2026-08-25T22:00:00+09:00")
        #expect(!RelativeDateStaleness.needsRefresh(spec: spec(.lastDays(30)),
                                                    lastEvaluatedAt: morning, now: evening,
                                                    calendar: calendar))
    }

    @Test("時間依存の条件が無ければ再評価しない（写真追加のドリフト検知に任せる）")
    func ignoresAbsoluteAndContentOnly() {
        let old = date("2026-01-01T00:00:00+09:00")
        let now = date("2026-08-25T00:10:00+09:00")
        #expect(!RelativeDateStaleness.needsRefresh(spec: spec(nil), lastEvaluatedAt: old,
                                                    now: now, calendar: calendar))
        #expect(!RelativeDateStaleness.needsRefresh(
            spec: spec(.absolute(date("2025-01-01T00:00:00Z"), date("2025-02-01T00:00:00Z"))),
            lastEvaluatedAt: old, now: now, calendar: calendar))
    }

    @Test("評価時刻の記録が無い旧データは 1 回だけ再評価する")
    func migratesLegacyInterpretations() {
        #expect(RelativeDateStaleness.needsRefresh(spec: spec(.lastMonths(1)),
                                                   lastEvaluatedAt: nil,
                                                   now: date("2026-08-25T00:10:00+09:00"),
                                                   calendar: calendar))
    }
}
