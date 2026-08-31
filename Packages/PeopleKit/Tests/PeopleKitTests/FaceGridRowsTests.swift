import Foundation
import Testing
@testable import PeopleKit

/// ⚠️ `List` の行の中に `LazyVGrid` を置くと、件数が増えたところで UIKit の assertion で落ちる
/// （実機 8/31 21:59・「さらに表示」で 24→48 にした直後）。行を固定列数で刻む方式に変えたので、
/// **刻み方**をここで固定する（並び順・端数・件数）。
@Suite("グリッドを行に刻む")
struct FaceGridRowsTests {

    @Test("列数ごとに分け、順序を保つ")
    func chunksInOrder() {
        let rows = FaceGridRows.chunked(Array(1...9), columns: 4)
        #expect(rows.count == 3)
        #expect(rows[0] == [1, 2, 3, 4])
        #expect(rows[1] == [5, 6, 7, 8])
        #expect(rows[2] == [9], "端数は最後の行に入る")
        #expect(rows.flatMap { $0 } == Array(1...9), "取りこぼし・重複が無い")
    }

    @Test("ちょうど割り切れるときは端数の行を作らない")
    func exactMultiple() {
        let rows = FaceGridRows.chunked(Array(1...8), columns: 4)
        #expect(rows.count == 2)
        #expect(rows.last?.count == 4)
    }

    @Test("空・不正な列数では行を作らない")
    func emptyOrInvalid() {
        #expect(FaceGridRows.chunked([Int](), columns: 4).isEmpty)
        #expect(FaceGridRows.chunked([1, 2, 3], columns: 0).isEmpty, "0 列で無限ループしない")
    }

    /// 「さらに表示」で件数が倍になっても、行数が比例して増えるだけであること。
    @Test("件数が増えても刻み方は変わらない")
    func scalesLinearly() {
        #expect(FaceGridRows.chunked(Array(1...24), columns: 4).count == 6)
        #expect(FaceGridRows.chunked(Array(1...48), columns: 4).count == 12)
    }
}
