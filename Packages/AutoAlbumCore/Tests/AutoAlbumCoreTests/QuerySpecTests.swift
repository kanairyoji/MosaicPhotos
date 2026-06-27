import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("RelativeDateParser")
struct RelativeDateParserTests {
    private let cal = Calendar(identifier: .gregorian)
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 27))! }

    private func kind(_ s: String) -> AIAlbumDateRange.Kind? {
        RelativeDateParser.parse(s, now: now, calendar: cal)?.kind
    }
    private func value(_ s: String) -> Int? {
        RelativeDateParser.parse(s, now: now, calendar: cal)?.value
    }

    @Test("ここN年 / last N years → lastYears(N)")
    func relativeYears() {
        #expect(RelativeDateParser.parse("ここ2年の子供の写真", now: now, calendar: cal) == .lastYears(2))
        #expect(RelativeDateParser.parse("past 5 years beach", now: now, calendar: cal) == .lastYears(5))
        #expect(RelativeDateParser.parse("直近3年", now: now, calendar: cal) == .lastYears(3))
    }

    @Test("月・日の相対")
    func relativeMonthsDays() {
        #expect(RelativeDateParser.parse("過去3ヶ月", now: now, calendar: cal) == .lastMonths(3))
        #expect(RelativeDateParser.parse("last 10 days", now: now, calendar: cal) == .lastDays(10))
        #expect(RelativeDateParser.parse("半年の写真", now: now, calendar: cal) == .lastMonths(6))
        #expect(RelativeDateParser.parse("最近の写真", now: now, calendar: cal) == .lastDays(30))
    }

    @Test("暦の固定表現（去年/今年/一昨年/N年前）")
    func calendarTerms() {
        #expect(RelativeDateParser.parse("去年の海", now: now, calendar: cal) == .year(2025))
        #expect(RelativeDateParser.parse("今年の写真", now: now, calendar: cal) == .year(2026))
        #expect(RelativeDateParser.parse("一昨年", now: now, calendar: cal) == .year(2024))
        #expect(RelativeDateParser.parse("3年前の旅行", now: now, calendar: cal) == .year(2023))
        #expect(RelativeDateParser.parse("last year", now: now, calendar: cal) == .year(2025))
    }

    @Test("西暦4桁は相対が無いときの保険")
    func absoluteYear() {
        #expect(RelativeDateParser.parse("2021年の写真", now: now, calendar: cal) == .year(2021))
        #expect(kind("子供の写真") == nil)
        _ = value("")
    }
}

@Suite("QueryEvaluator (hard filter / OR / NOT)")
struct QueryEvaluatorTests {
    private let cal = Calendar(identifier: .gregorian)
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 27))! }
    private func date(_ y: Int) -> Date { cal.date(from: DateComponents(year: y, month: 6, day: 1))! }

    private func photo(_ id: String, local: Bool = true, year: Int = 2025,
                       place: String? = nil, country: String? = nil, people: [String] = [],
                       favorite: Bool = false, screenshot: Bool = false,
                       aspect: Double? = nil, located: Bool = true) -> EnrichedPhoto {
        EnrichedPhoto(id: (local ? PhotoRef.local(id) : PhotoRef.cloud(id)).encoded,
                      captureDate: date(year),
                      latitude: located ? 35.0 : nil, longitude: located ? 135.0 : nil,
                      placeName: place, country: country, isScreenshot: screenshot,
                      isFavorite: favorite, aspect: aspect, people: people)
    }

    private func ids(_ ps: [EnrichedPhoto]) -> Set<String> { Set(ps.map(\.id)) }

    private var sample: [EnrichedPhoto] {
        [
            photo("kyoto", year: 2025, place: "Kyoto", country: "Japan",
                  people: ["Mom", "Kid"], favorite: true, aspect: 1.5),
            photo("osaka", year: 2020, place: "Osaka", country: "Japan",
                  people: [], aspect: 0.7, located: false),
            photo("shot", local: false, year: 2026, people: ["Kid"], screenshot: true, aspect: 0.5),
        ]
    }

    private func run(_ clauses: [QueryClause], exclScreens: Bool = true) -> Set<String> {
        ids(QueryEvaluator.hardFilter(sample, spec: QuerySpec(clauses: clauses, excludeScreenshots: exclScreens),
                                      now: now, calendar: cal))
    }

    @Test("空仕様は全件（スクショ除外は既定で効く）")
    func emptyMatchesAllButScreenshots() {
        let r = run([])
        #expect(r == Set([PhotoRef.local("kyoto").encoded, PhotoRef.local("osaka").encoded]))
    }

    @Test("相対日付 lastYears(2) は撮影日で絞る")
    func dateFilter() {
        let r = run([QueryClause([.date(.lastYears(2))])])
        #expect(r == Set([PhotoRef.local("kyoto").encoded]))   // 2025 のみ（2020 圏外・2026 はスクショ除外）
    }

    @Test("場所・人物・お気に入り・向き・位置")
    func facets() {
        #expect(run([QueryClause([.place(["kyoto"])])]) == Set([PhotoRef.local("kyoto").encoded]))
        #expect(run([QueryClause([.peopleAtLeast(1)])]) == Set([PhotoRef.local("kyoto").encoded]))
        #expect(run([QueryClause([.favorite])]) == Set([PhotoRef.local("kyoto").encoded]))
        #expect(run([QueryClause([.orientation(.portrait)])]) == Set([PhotoRef.local("osaka").encoded]))
        #expect(run([QueryClause([.hasLocation])]) == Set([PhotoRef.local("kyoto").encoded]))
    }

    @Test("NOT と ソース・スクショ")
    func negationAndSource() {
        // スクショ込みで cloud のみ → shot
        #expect(run([QueryClause([.source(.cloud)])], exclScreens: false)
                == Set([PhotoRef.cloud("shot").encoded]))
        // NOT(お気に入り)：スクショ除外下で kyoto 以外 → osaka
        #expect(run([QueryClause([.not(.favorite)])]) == Set([PhotoRef.local("osaka").encoded]))
    }

    @Test("OR（節）：京都 または 大阪")
    func orClauses() {
        let r = run([QueryClause([.place(["kyoto"])]), QueryClause([.place(["osaka"])])])
        #expect(r == Set([PhotoRef.local("kyoto").encoded, PhotoRef.local("osaka").encoded]))
    }

    @Test("content（ソフト）はハード評価では無視される")
    func contentIgnoredInHard() {
        // content だけの節はハード無条件 → 全件（スクショ除く）
        let r = run([QueryClause([.content(["children"])])])
        #expect(r == Set([PhotoRef.local("kyoto").encoded, PhotoRef.local("osaka").encoded]))
    }
}
