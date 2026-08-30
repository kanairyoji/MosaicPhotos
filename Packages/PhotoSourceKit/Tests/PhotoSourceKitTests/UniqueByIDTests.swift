import Foundation
import Testing
@testable import PhotoSourceKit

private struct MockItem: PhotoItem {
    let id: String
    let captureDate: Date?
}

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d
    c.timeZone = TimeZone(identifier: "UTC")
    return Calendar(identifier: .gregorian).date(from: c)!
}

/// グリッドのスナップショットに**同じ ID を 2 度入れない**（実機 diagnostics-69 のクラッシュ）。
///
/// `UICollectionViewDiffableDataSource` は重複識別子で例外を投げてアプリを落とす。
/// 一覧の重複はデータ側の異常（メンバー一覧に同じ写真が 2 回）だが、表示側は落ちてはいけない。
@Suite("一覧の ID 一意化")
struct UniqueByIDTests {

    @Test("重複は先勝ちで畳み、並び順は保つ")
    func firstWinsAndKeepsOrder() {
        let items = [
            MockItem(id: "a", captureDate: day(2020, 1, 1)),
            MockItem(id: "b", captureDate: day(2020, 1, 2)),
            MockItem(id: "a", captureDate: day(2020, 1, 3)),
            MockItem(id: "c", captureDate: day(2020, 1, 4)),
        ]
        let unique = uniquedByID(items)
        #expect(unique.map(\.id) == ["a", "b", "c"])
        #expect(unique[0].captureDate == day(2020, 1, 1), "先に出てきた方を残す")
    }

    @Test("重複が無ければそのまま")
    func noChangeWhenAlreadyUnique() {
        let items = (0..<5).map { MockItem(id: "\($0)", captureDate: day(2020, 1, $0 + 1)) }
        #expect(uniquedByID(items).map(\.id) == items.map(\.id))
    }

    @Test("文字列 ID 列も先勝ちで一意化する")
    func identifiersAreUniqued() {
        #expect(uniquedIdentifiers(["x", "y", "x", "z", "y"]) == ["x", "y", "z"])
        #expect(uniquedIdentifiers([]).isEmpty)
    }

    /// ⚠️ ここが本丸——**セクションに割り振ったあとの ID 列**が一意であること。
    /// 月グループは束ね直しが入るので、一意化を通したあとでも重複が残らないことを確かめる。
    @Test("月セクションへ割り振っても ID は一意のまま")
    func sectionedIDsStayUnique() {
        // 同じ写真が 2 回入った一覧（人物アルバムで実際に起きた形）。
        let raw = [
            MockItem(id: "L-1", captureDate: day(2018, 8, 1)),
            MockItem(id: "L-2", captureDate: day(2018, 8, 2)),
            MockItem(id: "L-1", captureDate: day(2018, 8, 1)),
            MockItem(id: "L-3", captureDate: day(2018, 9, 5)),
            MockItem(id: "L-3", captureDate: day(2018, 9, 5)),
        ]
        #expect(Set(raw.map(\.id)).count != raw.count, "前提: fixture に重複がある")

        let sections = photoGridSections(items: uniquedByID(raw), grouping: .month, colCount: 3)
        let ids = sections.flatMap { $0.rows.flatMap { $0.entries.map { $0.item.id } } }
        #expect(ids.count == 3, "重複を落とした 3 枚だけがセクションに入る")
        #expect(Set(ids).count == ids.count, "スナップショットに同じ ID が 2 度入るとアプリが落ちる")
    }
}
