import Foundation
import Testing
@testable import PhotoSourceKit

private struct SortMock: PhotoItem {
    let id: Int
    let captureDate: Date?
}

private func d(_ unix: TimeInterval) -> Date { Date(timeIntervalSince1970: unix) }

/// ⚠️ ここは**本番が呼ぶもの**（`sortByCaptureDateAscending` と、その比較式
/// `PhotoItemSorting.isBeforeByCaptureDate`）だけを叩く。
///
/// 以前は `sortedByCaptureDateDescending`（降順・戻り値版）を確かめていたが、
/// **本番からは 1 か所も呼ばれていなかった**——死んだ関数の性質を保証するだけで、
/// しかも本番が実際に使う昇順は無テストだった（`GridSignatureTests` が同じ轍を記録している）。
/// 関数ごと畳んで、テストを生きている方へ向け直した。
@Suite("Array<PhotoItem>.sortByCaptureDateAscending")
struct PhotoItemSortingTests {

    @Test("古い順（昇順）にその場で並べる")
    func ascendingOrder() {
        var items = [
            SortMock(id: 1, captureDate: d(300)),
            SortMock(id: 2, captureDate: d(100)),
            SortMock(id: 3, captureDate: d(200)),
        ]
        items.sortByCaptureDateAscending()
        #expect(items.map(\.id) == [2, 3, 1])
    }

    /// ⚠️ グリッドは下が新しい（`defaultScrollAnchor(.bottom)`）。nil を末尾に置くと
    /// 日時不明の写真が「最新」として一番下に出る。
    @Test("captureDate が nil の要素は先頭へ（最古扱い）")
    func nilGoesFirst() {
        var items = [
            SortMock(id: 1, captureDate: d(200)),
            SortMock(id: 2, captureDate: nil),
            SortMock(id: 3, captureDate: d(100)),
            SortMock(id: 4, captureDate: nil),
        ]
        items.sortByCaptureDateAscending()
        let ids = items.map(\.id)
        #expect(Set(ids.prefix(2)) == [2, 4], "nil が先頭に来ていない")
        #expect(ids.suffix(2) == [3, 1], "日付ありが昇順で末尾に来ていない")
    }

    @Test("空配列でも壊れない")
    func empty() {
        var items = [SortMock]()
        items.sortByCaptureDateAscending()
        #expect(items.isEmpty)
    }

    @Test("全て nil でも件数は変わらない")
    func allNil() {
        var items = [SortMock(id: 1, captureDate: nil), SortMock(id: 2, captureDate: nil)]
        items.sortByCaptureDateAscending()
        #expect(items.count == 2)
    }

    // MARK: - 比較式そのもの

    /// ⚠️ **`(nil, nil)` は false でなければならない**。true にすると `a<b` と `b<a` が
    /// 同時に成立して strict weak ordering が壊れ、`sort` の挙動が未定義になる
    /// （日時不明の写真が多い一覧で実際に踏み得る）。
    @Test("nil どうしは同順（どちらの向きでも false）")
    func nilPairIsUnordered() {
        let a = SortMock(id: 1, captureDate: nil)
        let b = SortMock(id: 2, captureDate: nil)
        #expect(!PhotoItemSorting.isBeforeByCaptureDate(a, b))
        #expect(!PhotoItemSorting.isBeforeByCaptureDate(b, a))
    }

    /// 同じ日時どうしも同順（どちらの向きでも false）。
    @Test("同じ日時どうしは同順")
    func equalDatesAreUnordered() {
        let a = SortMock(id: 1, captureDate: d(100))
        let b = SortMock(id: 2, captureDate: d(100))
        #expect(!PhotoItemSorting.isBeforeByCaptureDate(a, b))
        #expect(!PhotoItemSorting.isBeforeByCaptureDate(b, a))
    }

    @Test("nil は日付ありより前")
    func nilIsBeforeDated() {
        let undated = SortMock(id: 1, captureDate: nil)
        let dated = SortMock(id: 2, captureDate: d(100))
        #expect(PhotoItemSorting.isBeforeByCaptureDate(undated, dated))
        #expect(!PhotoItemSorting.isBeforeByCaptureDate(dated, undated))
    }
}
