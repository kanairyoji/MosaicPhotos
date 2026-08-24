import Foundation
import Testing
@testable import PhotoSourceKit

/// ⚠️ グリッドは指紋が変わらない限り snapshot と `idToIndex` を作り直さない。
/// 指紋が「件数＋両端の ID」だけだと、件数が同じまま中間が入れ替わった変化を取りこぼし、
/// **表示している写真とタップ時の ID が食い違う**（レビュー指摘）。
@Suite("gridIdentitySignature")
struct GridSignatureTests {

    @Test("同じ ID 列は同じ指紋")
    func stableForSameList() {
        #expect(gridIdentitySignature(["a", "b", "c"]) == gridIdentitySignature(["a", "b", "c"]))
    }

    /// 件数も両端も同じで**中間だけ差し替わった**ケース（旧実装が取りこぼしていた本命）。
    @Test("件数と両端が同じでも中間が変われば指紋が変わる")
    func detectsMiddleReplacement() {
        let before = gridIdentitySignature(["first", "x", "last"])
        let after = gridIdentitySignature(["first", "y", "last"])
        #expect(before != after, "中間の入れ替えを取りこぼす（別写真を表示してしまう）")
    }

    @Test("件数と両端が同じでも並びが変われば指紋が変わる")
    func detectsReordering() {
        let before = gridIdentitySignature(["first", "x", "y", "last"])
        let after = gridIdentitySignature(["first", "y", "x", "last"])
        #expect(before != after, "並び替えを取りこぼす（タップ時の ID が食い違う）")
    }

    /// 1 枚消えて 1 枚増える（同時到着）＝件数も両端も不変。
    @Test("同数の追加と削除が同時に起きても指紋が変わる")
    func detectsSwapWithSameCount() {
        let before = gridIdentitySignature(["a", "removed", "z"])
        let after = gridIdentitySignature(["a", "added", "z"])
        #expect(before != after)
    }

    @Test("件数が変われば指紋が変わる")
    func detectsCountChange() {
        #expect(gridIdentitySignature(["a", "b"]) != gridIdentitySignature(["a", "b", "c"]))
        #expect(gridIdentitySignature([String]()) != gridIdentitySignature(["a"]))
    }
}
