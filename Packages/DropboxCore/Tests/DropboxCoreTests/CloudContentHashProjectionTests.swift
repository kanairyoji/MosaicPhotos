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

    /// ⚠️ **作り直さない**（実機ログ diagnostics-90）。9.9 万行の射影は空いていて 1.8 秒、
    /// 顔スキャン・バックアップと重なると **17.1 秒**——その間この actor は塞がる。
    /// 表は増減のぶんだけ直し、2 回目以降は引き直さない。
    @Test("2 回目は引き直さない。増減のぶんだけ表を直す")
    func indexIsMaintainedIncrementally() async {
        let store = await store([item("/a.jpg", hash: "h1"), item("/b.jpg", hash: "h2")])

        _ = await store.cachedContentHashes()
        _ = await store.cachedContentHashes()
        #expect(await store.contentHashFetchesForTesting == 1, "変化が無いのに引き直している")

        // 1 枚増えて 1 枚消える → 引き直さずに表へ反映されること。
        await store.applyDelta(accountId: "acc1", added: [item("/c.jpg", hash: "h3")],
                               removed: ["/a.jpg"], newCursor: "c2")
        let after = await store.cachedContentHashes()

        #expect(after == ["/b.jpg": "h2", "/c.jpg": "h3"], "増減が表に反映されていない")
        #expect(await store.contentHashFetchesForTesting == 1, """
            delta のたびに 9.9 万行を引き直している（実機で 17 秒かかった形）。
            """)
    }

    /// ADR-119: 「1 回ぶんに見える呼び出し」が全列の実体化になっていないこと。**回数で見る**。
    @Test("射影は全列を実体化しない")
    func projectionDoesNotMaterializeAllColumns() async {
        let items = (0..<200).map { item("/p\($0).jpg", hash: "h\($0)") }
        let store = await store(items)
        let materializedBefore = await store.materializeCallsForTesting

        let hashes = await store.cachedContentHashes()

        #expect(hashes.count == items.count, "取りこぼしている")
        #expect(await store.contentHashFetchesForTesting == 1, "1 回の射影で取れていない")
        #expect(await store.materializeCallsForTesting == materializedBefore, """
            hash を取るために全列（67k 行）を実体化している。
            """)
    }
}
#endif
