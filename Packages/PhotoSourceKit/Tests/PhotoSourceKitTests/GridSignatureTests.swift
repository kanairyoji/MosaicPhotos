import Foundation
import Testing
@testable import PhotoSourceKit

/// ⚠️ グリッドは指紋が変わらない限り snapshot と `idToIndex` を作り直さない。
/// 指紋が「件数＋両端の ID」だけだと、件数が同じまま中間が入れ替わった変化を取りこぼし、
/// **表示している写真とタップ時の ID が食い違う**（レビュー指摘）。
/// テスト用のダミー写真（識別子と撮影日だけを動かす）。
private struct DatedItem: PhotoItem {
    let id: String
    let captureDate: Date?
}

/// ⚠️ ここは**本番が呼ぶ関数**（`gridContentSignature`）を直接叩く。
/// 以前は同じ性質を別関数（`gridIdentitySignature`）で確かめていたが、本番が
/// 呼ばなくなった時点で**死んだ関数の性質を保証する**だけになっていた
/// ——本物から `hasher.combine(count)` を消しても緑のままだった（レビュー 8 周目）。
@Suite("gridContentSignature（ID 列）")
struct GridSignatureTests {

    private func ids(_ list: [String]) -> [DatedItem] {
        list.map { DatedItem(id: $0, captureDate: nil) }
    }

    @Test("同じ ID 列は同じ指紋")
    func stableForSameList() {
        #expect(gridContentSignature(ids(["a", "b", "c"])) == gridContentSignature(ids(["a", "b", "c"])))
    }

    /// 件数も両端も同じで**中間だけ差し替わった**ケース（旧実装が取りこぼしていた本命）。
    @Test("件数と両端が同じでも中間が変われば指紋が変わる")
    func detectsMiddleReplacement() {
        let before = gridContentSignature(ids(["first", "x", "last"]))
        let after = gridContentSignature(ids(["first", "y", "last"]))
        #expect(before != after, "中間の入れ替えを取りこぼす（別写真を表示してしまう）")
    }

    @Test("件数と両端が同じでも並びが変われば指紋が変わる")
    func detectsReordering() {
        let before = gridContentSignature(ids(["first", "x", "y", "last"]))
        let after = gridContentSignature(ids(["first", "y", "x", "last"]))
        #expect(before != after, "並び替えを取りこぼす（タップ時の ID が食い違う）")
    }

    /// 1 枚消えて 1 枚増える（同時到着）＝件数も両端も不変。
    @Test("同数の追加と削除が同時に起きても指紋が変わる")
    func detectsSwapWithSameCount() {
        let before = gridContentSignature(ids(["a", "removed", "z"]))
        let after = gridContentSignature(ids(["a", "added", "z"]))
        #expect(before != after)
    }

    @Test("件数が変われば指紋が変わる")
    func detectsCountChange() {
        #expect(gridContentSignature(ids(["a", "b"])) != gridContentSignature(ids(["a", "b", "c"])))
        #expect(gridContentSignature(ids([])) != gridContentSignature(ids(["a"])))
    }
}

// MARK: - 同一実体の判定（指紋の再計算を省く）

/// ⚠️ サムネイルの密表示が重いという報告で、採取したメインスタックが
/// `Coordinator.update` → `gridContentSignature` → `MergedPhotoItem.id.getter` を
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
        // ⚠️ 本番と同じ要素型（撮影日を持つ写真）で確かめる。同一実体なら撮影日も同じなので、
        // 指紋を省いてよい——という根拠そのものを試す。
        let items = (0..<500).map {
            DatedItem(id: "L-\($0)", captureDate: Date(timeIntervalSince1970: Double($0)))
        }
        let copy = items
        #expect(sharesStorage(items, copy))
        #expect(gridContentSignature(items) == gridContentSignature(copy))
    }
}

/// 月の見出しは撮影日で決まるので、スナップショットを作り直すかの判定にも撮影日が要る。
@Suite("gridContentSignature（撮影日も混ぜる）")
struct GridContentSignatureTests {

    private func item(_ id: String, _ epoch: Double?) -> DatedItem {
        DatedItem(id: id, captureDate: epoch.map { Date(timeIntervalSince1970: $0) })
    }

    /// 回帰: **並びが同じでも撮影日が直れば作り直す**（ADR-199）。
    /// 共有フォルダは撮影順にアップロードされることが多いので、受け取った撮影日を
    /// 反映しても並びは変わらない。識別子だけで判定すると**月の見出しが古いまま**残る。
    @Test("並びが同じでも撮影日が変われば違う指紋")
    func captureDateChangesTheSignature() {
        // どちらも過去の日付（`CaptureDate.meaningful` の上限に掛からない値を使う）。
        let uploaded = [item("C-/f/a.jpg", 1_700_000_000), item("C-/f/b.jpg", 1_700_000_100)]
        let taken    = [item("C-/f/a.jpg", 1_000_000_000), item("C-/f/b.jpg", 1_000_000_100)]
        #expect(gridContentSignature(uploaded) != gridContentSignature(taken),
                "撮影日だけが直った更新を取りこぼす＝見出しがアップロード時刻のまま残る")
    }

    @Test("撮影日が同じなら同じ指紋（作り直さない）")
    func sameDatesSameSignature() {
        let a = [item("C-/f/a.jpg", 1_700_000_000), item("C-/f/b.jpg", 1_700_000_100)]
        let b = [item("C-/f/a.jpg", 1_700_000_000), item("C-/f/b.jpg", 1_700_000_100)]
        #expect(gridContentSignature(a) == gridContentSignature(b))
    }

    /// 撮影日の有無だけを見る実装（`captureDate != nil` を混ぜる等）に退行させない。
    @Test("撮影日が有る/無いだけでなく、値そのものを見る")
    func valueMattersNotJustPresence() {
        let early = [item("C-/f/a.jpg", 1_000_000_000)]
        let late  = [item("C-/f/a.jpg", 1_700_000_000)]
        let none  = [item("C-/f/a.jpg", nil)]
        #expect(gridContentSignature(early) != gridContentSignature(late))
        #expect(gridContentSignature(early) != gridContentSignature(none))
    }

    @Test("識別子が変われば違う指紋（元の性質を保つ）")
    func idStillMatters() {
        #expect(gridContentSignature([item("C-/f/a.jpg", 1_700_000_000)])
                != gridContentSignature([item("C-/f/b.jpg", 1_700_000_000)]))
    }

    // MARK: - 指紋が id を作らないこと（常駐メモリの棚卸し）

    /// `id` を読んだ回数を数えるアイテム。本番の `MergedPhotoItem` と同じく
    /// **`hashIdentity` を上書きして String を作らない**。
    private final class Counter: @unchecked Sendable { var reads = 0 }

    private struct CheapHashItem: PhotoItem, @unchecked Sendable {
        let raw: Int
        let counter: Counter
        var id: String {
            counter.reads += 1
            return "C-/folder/\(raw).jpg"      // 本番と同じく毎回組み立てる
        }
        var captureDate: Date? { nil }
        /// 種別＋中身を直接混ぜる（String を作らない）。
        func hashIdentity(into hasher: inout Hasher) {
            hasher.combine(1 as UInt8)
            hasher.combine(raw)
        }
        static func == (l: CheapHashItem, r: CheapHashItem) -> Bool { l.raw == r.raw }
        func hash(into hasher: inout Hasher) { hasher.combine(raw) }
    }

    /// ⚠️ 指紋は「作り直しを避ける」ための節約策なのに、その判定自体が全件ぶんの
    /// String 確保になっていた（ズームで列数を変えるだけでも走る）。
    @Test("指紋の計算で id を 1 本も作らない")
    func signatureBuildsNoIDs() {
        let counter = Counter()
        let list = (0..<5_000).map { CheapHashItem(raw: $0, counter: counter) }
        _ = gridContentSignature(list)
        #expect(counter.reads == 0,
                "指紋が hashIdentity を通っていない（id を \(counter.reads) 回作った）")
    }

    /// 規模を 4 倍にしても回数が比例しないこと（ADR-119 の形・回数は決定的）。
    @Test("規模を 4 倍にしても id の生成回数は増えない")
    func signatureScaleDoesNotBuildIDs() {
        func reads(_ n: Int) -> Int {
            let counter = Counter()
            _ = gridContentSignature((0..<n).map { CheapHashItem(raw: $0, counter: counter) })
            return counter.reads
        }
        let small = reads(2_500)
        let large = reads(10_000)
        #expect(small == 0 && large == 0,
                "規模に比例して id を作っている（2,500件=\(small) / 10,000件=\(large)）")
    }

    /// ⚠️ 上書きしても**区別できること**。`hashIdentity` で種別を混ぜ忘れると、
    /// 端末写真とクラウド写真で同じ中身が来たときに同一視される。
    @Test("hashIdentity を上書きしても中身の違いは指紋に出る")
    func cheapHashStillDistinguishes() {
        let counter = Counter()
        let a = [CheapHashItem(raw: 1, counter: counter)]
        let b = [CheapHashItem(raw: 2, counter: counter)]
        #expect(gridContentSignature(a) != gridContentSignature(b))
    }
}
