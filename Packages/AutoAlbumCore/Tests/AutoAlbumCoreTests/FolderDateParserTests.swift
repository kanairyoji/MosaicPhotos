import Foundation
import Testing
@testable import AutoAlbumCore

@Suite("FolderDateParser")
struct FolderDateParserTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 6, day: 27))! }

    private func parse(_ s: String, locale: Locale = Locale(identifier: "ja_JP")) -> FolderDate? {
        FolderDateParser.parse(s, calendar: cal, locale: locale, now: now)
    }
    private func ymd(_ d: Date) -> (Int, Int, Int) {
        (cal.component(.year, from: d), cal.component(.month, from: d), cal.component(.day, from: d))
    }

    @Test("年-月-日（区切り/圧縮/和暦）→ day")
    func dayForms() {
        for s in ["2023-08-15 Hawaii", "2023/8/15", "2023.08.15", "20230815_旅行", "2023年8月15日"] {
            let fd = parse(s)
            #expect(fd?.granularity == .day, "\(s)")
            if let fd { #expect(ymd(fd.start) == (2023, 8, 15), "\(s)") }
        }
    }

    @Test("年-月（区切り/圧縮/和暦）→ month")
    func monthForms() {
        for s in ["2023-08 Hawaii", "2023/8", "202308", "2023年8月"] {
            let fd = parse(s)
            #expect(fd?.granularity == .month, "\(s)")
            if let fd {
                #expect(ymd(fd.start) == (2023, 8, 1), "\(s)")
                #expect(cal.component(.month, from: fd.end) == 8)   // 月末まで
            }
        }
    }

    @Test("年のみ → year")
    func yearForms() {
        for s in ["2023", "Hawaii 2023", "2023年", "家族旅行_2023"] {
            let fd = parse(s)
            #expect(fd?.granularity == .year, "\(s)")
            if let fd {
                #expect(ymd(fd.start) == (2023, 1, 1), "\(s)")
                #expect(ymd(fd.end) == (2023, 12, 31), "\(s)")
            }
        }
    }

    @Test("英語月名 → day / month")
    func monthNames() {
        #expect(ymd(parse("August 15, 2023")!.start) == (2023, 8, 15))
        #expect(ymd(parse("15 Aug 2023")!.start) == (2023, 8, 15))
        let m = parse("Aug 2023")
        #expect(m?.granularity == .month)
        #expect(ymd(m!.start) == (2023, 8, 1))
        #expect(ymd(parse("2023 September")!.start) == (2023, 9, 1))
    }

    @Test("曖昧な数値日付はロケールで解決（>12 は日と確定）")
    func ambiguous() {
        // 05/06/2023: en_US は月→日（5月6日）、en_GB は日→月（6月5日）
        #expect(ymd(parse("05/06/2023", locale: Locale(identifier: "en_US"))!.start) == (2023, 5, 6))
        #expect(ymd(parse("05/06/2023", locale: Locale(identifier: "en_GB"))!.start) == (2023, 6, 5))
        // 15/06/2023: 15>12 なので日と確定（ロケール不問）
        #expect(ymd(parse("15/06/2023", locale: Locale(identifier: "en_US"))!.start) == (2023, 6, 15))
    }

    @Test("範囲 → range（start..end）")
    func ranges() {
        let fd = parse("2023-08-15〜2023-08-20")
        #expect(fd?.granularity == .range)
        if let fd {
            #expect(ymd(fd.start) == (2023, 8, 15))
            #expect(ymd(fd.end) == (2023, 8, 20))
        }
        let fd2 = parse("2023-08 to 2023-10")
        #expect(fd2?.granularity == .range)
        if let fd2 { #expect(cal.component(.month, from: fd2.end) == 10) }
    }

    @Test("日付なしは nil")
    func noDate() {
        #expect(parse("Hawaii") == nil)
        #expect(parse("家族旅行") == nil)
        #expect(parse("camera roll") == nil)
    }

    @Test("不正な日付は弾く（Feb 30 等）")
    func invalid() {
        #expect(parse("2023-02-30") == nil || parse("2023-02-30")?.granularity != .day)
    }
}
