import Foundation
import Testing
@testable import PhotoSourceKit

/// テスト用のダミー写真アイテム。
private struct MockItem: PhotoItem {
    let id: Int
    let captureDate: Date?
}

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}

@Suite("PhotoGridGrouping")
struct PhotoGridGroupingTests {

    @Test("空配列はセクションなし")
    func emptyItems() {
        let sections = photoGridSections(items: [MockItem](), grouping: .month, colCount: 3)
        #expect(sections.isEmpty)
    }

    @Test("月グループは隣接する同月を1セクションにまとめる")
    func monthGrouping() {
        let items = [
            MockItem(id: 0, captureDate: date(2018, 8, 1)),
            MockItem(id: 1, captureDate: date(2018, 8, 20)),
            MockItem(id: 2, captureDate: date(2018, 9, 3)),
        ]
        let sections = photoGridSections(items: items, grouping: .month, colCount: 3)
        #expect(sections.count == 2)
        #expect(sections[0].title == "2018-08")
        #expect(sections[0].rows.first?.entries.count == 2)
        #expect(sections[1].title == "2018-09")
    }

    @Test("年グループは同年を1セクションにまとめる")
    func yearGrouping() {
        let items = [
            MockItem(id: 0, captureDate: date(2018, 1, 1)),
            MockItem(id: 1, captureDate: date(2018, 12, 31)),
            MockItem(id: 2, captureDate: date(2019, 6, 1)),
        ]
        let sections = photoGridSections(items: items, grouping: .year, colCount: 30)
        #expect(sections.map(\.title) == ["2018", "2019"])
    }

    @Test("coalesceBelow: 1行に満たない連続月を範囲セクションへ束ねる")
    func coalescesSmallMonths() {
        // colCount=4。各月が1〜2枚（<4）→ 連続して束ねられ、密に詰まる。
        let items = [
            MockItem(id: 0, captureDate: date(2024, 1, 5)),
            MockItem(id: 1, captureDate: date(2024, 2, 9)),
            MockItem(id: 2, captureDate: date(2024, 2, 20)),
            MockItem(id: 3, captureDate: date(2024, 3, 1)),
        ]
        let sections = photoGridSections(items: items, grouping: .month, colCount: 4, coalesceBelow: 4)
        #expect(sections.count == 1)                        // 3か月が1セクションに
        #expect(sections[0].title == "2024-01 – 2024-03")   // 範囲ラベル
        #expect(sections[0].rows.count == 1)                // 4枚=1行に密集
        #expect(sections[0].rows[0].entries.map(\.flatIndex) == [0, 1, 2, 3])
    }

    @Test("coalesceBelow: 連続して各1行ぶん埋まる月はそれぞれ単独セクション")
    func keepsFullMonthsStandalone() {
        // 2024-01・2024-02 がそれぞれ4枚（=colCount）→ 各々で1行ぶん埋まるので単独セクション。
        let items = (0..<4).map { MockItem(id: $0, captureDate: date(2024, 1, 1)) }
            + (4..<8).map { MockItem(id: $0, captureDate: date(2024, 2, 1)) }
        let sections = photoGridSections(items: items, grouping: .month, colCount: 4, coalesceBelow: 4)
        #expect(sections.map(\.title) == ["2024-01", "2024-02"])
    }

    @Test("coalesceBelow: 末尾の1行未満の月は直前セクションへ畳み込む（最大密度）")
    func foldsTrailingSmallMonthIntoPrevious() {
        // 2024-01 が4枚（=colCount・単独成立）だが、末尾の 2024-02(1枚) は単独にせず直前へ畳み込む。
        let items = (0..<4).map { MockItem(id: $0, captureDate: date(2024, 1, 1)) }
            + [MockItem(id: 4, captureDate: date(2024, 2, 1))]
        let sections = photoGridSections(items: items, grouping: .month, colCount: 4, coalesceBelow: 4)
        #expect(sections.count == 1)
        #expect(sections[0].title == "2024-01 – 2024-02")
        #expect(sections[0].rows.count == 2)                     // 4 + 1
        #expect(sections[0].rows[1].entries.map(\.flatIndex) == [4])
    }

    @Test("coalesceBelow: 大きい月に挟まれた小さい月も孤立させず密に詰める")
    func packsIsolatedSmallMonths() {
        // 1月(1)・2月(4)・3月(1)。2月で1行ぶん埋まり、末尾3月は直前へ畳み込む → 全体1セクション。
        let items = [MockItem(id: 0, captureDate: date(2024, 1, 1))]
            + (1..<5).map { MockItem(id: $0, captureDate: date(2024, 2, 1)) }
            + [MockItem(id: 5, captureDate: date(2024, 3, 1))]
        let sections = photoGridSections(items: items, grouping: .month, colCount: 4, coalesceBelow: 4)
        #expect(sections.count == 1)
        #expect(sections[0].title == "2024-01 – 2024-03")
    }

    @Test("captureDate が nil のものは Unknown セクション")
    func unknownDate() {
        let items = [MockItem(id: 0, captureDate: nil)]
        let sections = photoGridSections(items: items, grouping: .month, colCount: 3)
        #expect(sections.count == 1)
        #expect(sections[0].title == "Unknown")
    }

    @Test("colCount ごとに行へ分割し flatIndex を保持する")
    func chunkingPreservesFlatIndex() {
        let items = (0..<5).map { MockItem(id: $0, captureDate: date(2020, 1, 1)) }
        let sections = photoGridSections(items: items, grouping: .month, colCount: 2)
        #expect(sections.count == 1)
        let rows = sections[0].rows
        #expect(rows.count == 3)                 // 2 + 2 + 1
        #expect(rows[0].entries.map(\.flatIndex) == [0, 1])
        #expect(rows[1].entries.map(\.flatIndex) == [2, 3])
        #expect(rows[2].entries.map(\.flatIndex) == [4])
        #expect(rows[0].id == 0)                 // 行頭エントリの flatIndex
        #expect(rows[1].id == 2)
    }
}
