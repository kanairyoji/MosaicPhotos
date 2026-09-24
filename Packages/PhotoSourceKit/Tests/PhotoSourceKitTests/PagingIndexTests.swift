import Foundation
import Testing
@testable import PhotoSourceKit

/// ⚠️ フル画面ビューが 18 秒級のハングを繰り返し、採取したメインスタックが
/// `PhotoPageView.currentItem` → `MergedPhotoItem.id.getter : Swift.String` を名指ししていた
/// （実機 diagnostics-58）。9 万件を毎回線形走査し、合成 id は呼ばれるたびに文字列を作り直す。
/// 当たり（直前の位置）が効いていれば探索しないこと、外れても正しく解けることを押さえる。
@Suite("現在位置の解決")
struct PagingIndexTests {

    /// `id` を読んだ回数を数えるアイテム（走査が起きたかを直接観測する）。
    private final class Counter: @unchecked Sendable {
        var reads = 0
    }

    private struct CountingItem: PhotoItem, @unchecked Sendable {
        let raw: Int
        let counter: Counter
        var id: String {
            counter.reads += 1
            return "L-\(raw)"          // 本番と同じく**毎回組み立てる**
        }
        var captureDate: Date? { nil }

        static func == (lhs: CountingItem, rhs: CountingItem) -> Bool { lhs.raw == rhs.raw }
        func hash(into hasher: inout Hasher) { hasher.combine(raw) }
    }

    /// `MergedPhotoItem` と同じく **`hasID` を上書きして id を作らない**アイテム。
    /// 本番の実装がそうなっているので、走査の経路がそれを通っているかはこちらで押さえる。
    private struct CheapCompareItem: PhotoItem, @unchecked Sendable {
        let raw: Int
        let counter: Counter
        var id: String {
            counter.reads += 1
            return "L-\(raw)"
        }
        var captureDate: Date? { nil }
        /// 接頭辞と中身を直接見る（String を作らない）。
        func hasID(_ candidate: String) -> Bool {
            candidate.hasPrefix("L-") && candidate.dropFirst(2) == "\(raw)"
        }

        static func == (lhs: CheapCompareItem, rhs: CheapCompareItem) -> Bool { lhs.raw == rhs.raw }
        func hash(into hasher: inout Hasher) { hasher.combine(raw) }
    }

    private func items(_ count: Int, _ counter: Counter) -> [CountingItem] {
        (0..<count).map { CountingItem(raw: $0, counter: counter) }
    }

    private func cheapItems(_ count: Int, _ counter: Counter) -> [CheapCompareItem] {
        (0..<count).map { CheapCompareItem(raw: $0, counter: counter) }
    }

    @Test("当たっていれば探索しない")
    func hintHitAvoidsScan() {
        let counter = Counter()
        let list = items(10_000, counter)
        let index = PagingIndex.resolve(list, id: "L-7000", hint: 7000)
        #expect(index == 7000)
        #expect(counter.reads == 1, "当たりの検証だけで済むはず（実際は \(counter.reads) 回読んだ）")
    }

    @Test("外れたら探し直す")
    func hintMissFallsBack() {
        let counter = Counter()
        let list = items(100, counter)
        #expect(PagingIndex.resolve(list, id: "L-42", hint: 10) == 42)
    }

    @Test("当たりが範囲外でも壊れない")
    func hintOutOfRange() {
        let counter = Counter()
        let list = items(10, counter)
        #expect(PagingIndex.resolve(list, id: "L-3", hint: 999) == 3)
        #expect(PagingIndex.resolve(list, id: "L-3", hint: -1) == 3)
    }

    @Test("当たりが無ければ探索する")
    func noHint() {
        let counter = Counter()
        #expect(PagingIndex.resolve(items(50, counter), id: "L-49", hint: nil) == 49)
    }

    @Test("居ない id は nil")
    func missing() {
        let counter = Counter()
        #expect(PagingIndex.resolve(items(50, counter), id: "L-999", hint: 3) == nil)
    }

    @Test("空の一覧でも壊れない")
    func empty() {
        let counter = Counter()
        #expect(PagingIndex.resolve(items(0, counter), id: "L-0", hint: 0) == nil)
    }

    @Test("要素を直接取れる")
    func itemLookup() {
        let counter = Counter()
        let list = items(100, counter)
        #expect(PagingIndex.item(list, id: "L-5", hint: 5)?.raw == 5)
        #expect(PagingIndex.item(list, id: "L-999", hint: 5) == nil)
    }

    // MARK: - 走査が id を作らないこと（常駐メモリの棚卸し）

    /// ⚠️ **当たりが外れたときこそ効かせたい**。当たっていれば 1 回で済むのは当然で、
    /// 問題は全件走査に落ちた回に 12 万本の String を作っていたこと。`hasID` を
    /// 上書きした実装（＝本番の `MergedPhotoItem`）なら、走査しても **1 本も作らない**。
    @Test("外れて全件走査しても id を作らない")
    func fullScanBuildsNoIDs() {
        let counter = Counter()
        let list = cheapItems(5_000, counter)
        #expect(PagingIndex.resolve(list, id: "L-4999", hint: 0) == 4999)
        #expect(counter.reads == 0,
                "走査が hasID を通っていない（id を \(counter.reads) 回作った）")
    }

    /// ⚠️ 規模を 4 倍にしても**回数が比例して増えない**こと（ADR-119 の形）。
    /// 時間は CI で揺れるが回数は決定的なので、回数で固定する。
    @Test("規模を 4 倍にしても id の生成回数は増えない")
    func scaleDoesNotIncreaseIDBuilds() {
        func reads(_ n: Int) -> Int {
            let counter = Counter()
            let list = cheapItems(n, counter)
            _ = PagingIndex.resolve(list, id: "L-\(n - 1)", hint: nil)   // 最悪＝末尾まで走査
            return counter.reads
        }
        let small = reads(2_500)
        let large = reads(10_000)
        #expect(small == 0 && large == 0,
                "規模に比例して id を作っている（2,500件=\(small) 回 / 10,000件=\(large) 回）")
    }

    /// 居ない id を全件走査で探す場合も同じ（早期 return が無いぶん最悪ケース）。
    @Test("居ない id を探しても作らない")
    func missingIDBuildsNoIDs() {
        let counter = Counter()
        let list = cheapItems(3_000, counter)
        #expect(PagingIndex.resolve(list, id: "L-999999", hint: 7) == nil)
        #expect(counter.reads == 0, "id を \(counter.reads) 回作った")
    }
}
