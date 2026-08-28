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

// MARK: - 同一実体の判定（指紋の再計算を省く）

/// ⚠️ サムネイルの密表示が重いという報告で、採取したメインスタックが
/// `Coordinator.update` → `gridIdentitySignature` → `MergedPhotoItem.id.getter` を
/// 名指ししていた（実機 diagnostics-59）。ズームで列数を変えるだけでも updateUIView は
/// 走るため、中身が 1 つも変わっていないのに 86,000 件ぶんの文字列生成をやり直していた。
@Suite("配列の同一実体判定")
struct SharesStorageTests {

    @Test("同じ配列は同じ実体")
    func sameArrayShares() {
        let items = Array(0..<1000)
        let copy = items                       // COW＝バッファは共有
        #expect(sharesStorage(items, copy))
    }

    @Test("作り直した配列は別実体")
    func rebuiltArrayDiffers() {
        let items = Array(0..<1000)
        let rebuilt = Array(0..<1000)
        #expect(!sharesStorage(items, rebuilt),
                "別実体なら指紋を取り直す＝安全側（偽陰性はただ計算するだけ）")
    }

    @Test("書き換えた時点で別実体になる")
    func mutationBreaksSharing() {
        let items = Array(0..<1000)
        var changed = items
        changed[500] = -1                      // ここで COW のコピーが起きる
        #expect(!sharesStorage(items, changed), "変化を取りこぼすと別の写真が表示される")
    }

    @Test("件数が違えば別実体")
    func differentCount() {
        let items = Array(0..<1000)
        #expect(!sharesStorage(items, Array(items.dropLast())))
    }

    @Test("空同士は同じ扱い（どちらも中身なし）")
    func emptyArrays() {
        #expect(sharesStorage([Int](), [Int]()))
    }

    /// 同一実体と判定したときは、指紋も必ず一致していること（省いてよい根拠）。
    @Test("同一実体なら指紋も一致する")
    func sharedStorageImpliesSameSignature() {
        let items = (0..<500).map { "L-\($0)" }
        let copy = items
        #expect(sharesStorage(items, copy))
        #expect(gridIdentitySignature(items) == gridIdentitySignature(copy))
    }
}
