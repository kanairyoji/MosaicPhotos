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
