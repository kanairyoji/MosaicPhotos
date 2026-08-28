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

    private struct CountingItem: Identifiable {
        let raw: Int
        let counter: Counter
        var id: String {
            counter.reads += 1
            return "L-\(raw)"          // 本番と同じく**毎回組み立てる**
        }
    }

    private func items(_ count: Int, _ counter: Counter) -> [CountingItem] {
        (0..<count).map { CountingItem(raw: $0, counter: counter) }
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
}
