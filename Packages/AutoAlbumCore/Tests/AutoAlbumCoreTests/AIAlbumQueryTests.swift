import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("AI album query (date / filter / rule-based)")
struct AIAlbumQueryTests {

    private let cal = Calendar(identifier: .gregorian)
    /// 2024-06-15 を「現在」とする固定日時（UTC）。
    private var now: Date {
        DateComponents(calendar: cal, timeZone: TimeZone(identifier: "UTC"),
                       year: 2024, month: 6, day: 15).date!
    }

    private func photo(_ id: String, year: Int, place: String? = nil, country: String? = nil,
                       people: [String] = [], favorite: Bool = false, screenshot: Bool = false) -> EnrichedPhoto {
        let date = DateComponents(calendar: cal, timeZone: TimeZone(identifier: "UTC"),
                                  year: year, month: 7, day: 1).date!
        return EnrichedPhoto(id: PhotoRef.local(id).encoded, captureDate: date, latitude: nil, longitude: nil,
                             placeName: place, country: country, isScreenshot: screenshot,
                             isFavorite: favorite, people: people)
    }

    // MARK: - Date range

    @Test("year は当該年の1年間に展開する")
    func resolvesYear() {
        let (s, e) = AIAlbumDateRange.year(2022).resolved(now: now, calendar: utcCal)
        #expect(utcCal.component(.year, from: s) == 2022)
        #expect(utcCal.component(.month, from: s) == 1)
        #expect(utcCal.component(.year, from: e) == 2022)
        #expect(utcCal.component(.month, from: e) == 12)
    }

    @Test("lastYears は現在から N 年前〜現在")
    func resolvesLastYears() {
        let (s, e) = AIAlbumDateRange.lastYears(3).resolved(now: now, calendar: utcCal)
        #expect(utcCal.component(.year, from: s) == 2021)
        #expect(e == now)
    }

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // MARK: - Filter

    @Test("場所はカタログ語彙で接地（相対期間はハードコードしないので nil）")
    func interpretsPlaceNoRelativeDate() async {
        let catalog = AIAlbumCatalog(places: ["沖縄", "京都"], countries: ["日本"], people: [], earliest: nil, latest: nil)
        let q = await RuleBasedQueryUnderstanding().interpret("ここ数年の沖縄の写真", catalog: catalog, now: now)
        #expect(q.placeTerms.contains("沖縄"))
        #expect(q.dateRange == nil)   // 「ここ数年」は FM に委ね、ルールベースは拾わない
    }

    @Test("お気に入りと相対年「去年」を拾う（RelativeDateParser 統合）")
    func interpretsFavorites() async {
        let catalog = AIAlbumCatalog(places: [], countries: [], people: [], earliest: nil, latest: nil)
        let q = await RuleBasedQueryUnderstanding().interpret("去年のお気に入り", catalog: catalog, now: now)
        #expect(q.favoritesOnly)
        #expect(q.dateRange == .year(2023))   // now=2024 → 去年=2023（旧仕様の「拾わない」から変更）
    }

    @Test("人物名と西暦4桁は拾う")
    func interpretsPersonAndYear() async {
        let catalog = AIAlbumCatalog(places: [], countries: [], people: ["Mom", "Taro"], earliest: nil, latest: nil)
        let q = await RuleBasedQueryUnderstanding().interpret("2021 photos with Mom", catalog: catalog, now: now)
        #expect(q.peopleTerms == ["Mom"])
        #expect(q.dateRange == .year(2021))
        #expect(q.keywords.isEmpty)   // 内容語の辞書抽出は行わない（CLIP に委ねる）
    }
}
