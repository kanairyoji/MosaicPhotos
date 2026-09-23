#if canImport(UIKit)
import Foundation
import MosaicSupport
import Testing
@testable import DropboxCore

/// **クラウド写真の content_hash を、表示用の配列から拾わない**（ADR-222・実機ログ diagnostics-84）。
///
/// ⚠️ 何を踏んだか: 解析の公開が毎回「クラウド写真が 0 件」で何もしていなかった。原因は
/// `DropboxPhotoStore.items`（表示用）から hash を拾っていたこと——`cachedItems` が作る
/// `DropboxFileItem` は content_hash を**わざと nil にする**（67k 件の長寿命配列に 64 桁の
/// 文字列を常駐させないため）。しかも `items` は画面を開いたときだけ作られるので、背景の窓では
/// そもそも空になり得る。つまり**動いているように見えて、何も見ていなかった**。
///
/// ここでは (1) 台帳の射影が hash を返すこと、(2) 表示用アイテムには hash が無いこと（＝拾い先を
/// 間違えたら必ずここで落ちること）、(3) 射影が全列を実体化しないこと（ADR-119・回数で見る）を固定する。
@Suite("クラウド写真の content_hash（射影・ADR-222）")
struct CloudContentHashProjectionTests {

    private func store(_ items: [DropboxFileItem]) async -> DropboxCacheStore {
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "acc1", added: items, removed: [], newCursor: "c1")
        return store
    }

    private func item(_ path: String, hash: String?) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent, contentHash: hash,
                        captureDate: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("台帳の射影はパス小文字 → hash を返す（hash が無い行は落とす）")
    func projectionReturnsHashes() async {
        let store = await store([item("/A.jpg", hash: "h1"), item("/b.jpg", hash: "h2"),
                                 item("/c.jpg", hash: nil)])

        let hashes = await store.cachedContentHashes()

        #expect(hashes == ["/a.jpg": "h1", "/b.jpg": "h2"])
    }

    /// ⚠️ **ここが本丸**。表示用アイテムから hash を拾う実装に戻したら、このテストが
    /// 「拾えるはずがない」ことを示す（実機で 0 件になる前に落ちる）。
    @Test("表示用のアイテムは content_hash を持たない（拾い先にしてはいけない）")
    func displayItemsCarryNoHash() async {
        let store = await store([item("/a.jpg", hash: "h1")])

        let displayed = await store.cachedItems(accountId: "acc1")

        #expect(displayed.count == 1)
        #expect(displayed.first?.contentHash == nil, """
            表示用アイテムが hash を持つようになった。持たせるなら 67k 件の常駐メモリを
            測り直すこと。持たせないなら、hash の取得は `cachedContentHashes()` を使う。
            """)
    }

    /// ADR-119: 「1 回ぶんに見える呼び出し」が全列の実体化になっていないこと。**回数で見る**。
    @Test("射影は全列を実体化しない")
    func projectionDoesNotMaterializeAllColumns() async {
        let items = (0..<200).map { item("/p\($0).jpg", hash: "h\($0)") }
        let store = await store(items)
        PerfTrace.setEnabledForTesting(true)
        _ = PerfTrace.takeCounts()

        let hashes = await store.cachedContentHashes()
        let counts = PerfTrace.takeCounts()
        PerfTrace.setEnabledForTesting(false)

        #expect(hashes.count == items.count, "取りこぼしている")
        #expect(counts["cache.contentHashes.fetch"] == 1, "1 回の射影で取れていない")
        #expect((counts["cache.itemsMaterialized"] ?? 0) == 0, """
            hash を取るために全列（67k 行）を実体化している。
            """)
    }
}
#endif
