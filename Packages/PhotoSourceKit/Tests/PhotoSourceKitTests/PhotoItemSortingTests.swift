import Foundation
import Testing
@testable import PhotoSourceKit

private struct SortMock: PhotoItem {
    let id: Int
    let captureDate: Date?
}

private func d(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

@Suite("Array<PhotoItem>.sortedByCaptureDateDescending")
struct PhotoItemSortingTests {

    @Test("新しい順（降順）に並べる")
    func descendingOrder() {
        let items = [
            SortMock(id: 1, captureDate: d(100)),
            SortMock(id: 2, captureDate: d(300)),
            SortMock(id: 3, captureDate: d(200)),
        ]
        #expect(items.sortedByCaptureDateDescending().map(\.id) == [2, 3, 1])
    }

    @Test("captureDate が nil の要素は末尾へ")
    func nilGoesLast() {
        let items = [
            SortMock(id: 1, captureDate: nil),
            SortMock(id: 2, captureDate: d(200)),
            SortMock(id: 3, captureDate: nil),
            SortMock(id: 4, captureDate: d(100)),
        ]
        let sorted = items.sortedByCaptureDateDescending().map(\.id)
        #expect(sorted.prefix(2) == [2, 4])     // 日付ありが先頭、降順
        #expect(Set(sorted.suffix(2)) == [1, 3]) // nil は末尾（順不同）
    }

    @Test("空配列は空のまま")
    func empty() {
        #expect([SortMock]().sortedByCaptureDateDescending().isEmpty)
    }

    @Test("全て nil ならそのまま残る")
    func allNil() {
        let items = [SortMock(id: 1, captureDate: nil), SortMock(id: 2, captureDate: nil)]
        #expect(items.sortedByCaptureDateDescending().count == 2)
    }
}
