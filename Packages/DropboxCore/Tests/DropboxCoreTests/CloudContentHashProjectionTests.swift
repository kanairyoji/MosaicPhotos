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
        #expect(await store.itemIndexBuildsForTesting == 1, "変化が無いのに引き直している")

        // 1 枚増えて 1 枚消える → 引き直さずに表へ反映されること。
        await store.applyDelta(accountId: "acc1", added: [item("/c.jpg", hash: "h3")],
                               removed: ["/a.jpg"], newCursor: "c2")
        let after = await store.cachedContentHashes()

        #expect(after == ["/b.jpg": "h2", "/c.jpg": "h3"], "増減が表に反映されていない")
        #expect(await store.itemIndexBuildsForTesting == 1, """
            delta のたびに 9.9 万行を引き直している（実機で 17 秒かかった形）。
            """)
    }

    /// ⚠️ **訊いて得た撮影日時を、同期の日付で潰さない**（ADR-201 と同じ決まり）。
    /// 表は増減で直すので、ここを間違えると解析の処理順（新しい写真から）が狂う。
    @Test("EXIF で訊き直した撮影日は、同じ中身の再同期で戻らない")
    func probedCaptureDateSurvivesResync() async {
        let uploaded = Date(timeIntervalSince1970: 1_700_000_000)
        let shot = Date(timeIntervalSince1970: 1_400_000_000)
        let store = DropboxCacheStore(isStoredInMemoryOnly: true)
        await store.applyDelta(accountId: "acc1",
                               added: [DropboxFileItem(path: "/a.jpg", name: "a.jpg",
                                                       contentHash: "h1", captureDate: uploaded)],
                               removed: [], newCursor: "c1")
        _ = await store.cachedPhotoRefs()                       // 表を作る
        _ = await store.recordCaptureDateProbe(path: "/a.jpg", captureDate: shot,
                                               latitude: nil, longitude: nil)
        #expect(await store.cachedPhotoRefs().first?.captureDate == shot, "訊いた日付が表に入っていない")

        // 同じ中身がもう一度 delta で来ても、アップロード時刻で戻らないこと。
        await store.applyDelta(accountId: "acc1",
                               added: [DropboxFileItem(path: "/a.jpg", name: "a.jpg",
                                                       contentHash: "h1", captureDate: uploaded)],
                               removed: [], newCursor: "c2")
        #expect(await store.cachedPhotoRefs().first?.captureDate == shot, """
            再同期でアップロード時刻に戻った（解析の処理順が狂う・ADR-201）。
            """)
    }

    /// ⚠️ **ページの継ぎ目で取りこぼさない**（`FaceStore` の outlier ページングで実際に踏んだ形）。
    /// 表はページ分けして作るので、境界をまたぐ規模で全件そろうことを固定する。
    @Test("ページの大きさを超えても全件そろう")
    func indexCoversEveryPage() async {
        let count = DropboxCacheStore.indexPageSize + 37
        let items = (0..<count).map { item(String(format: "/p%06d.jpg", $0), hash: "h\($0)") }
        let store = await store(items)

        let hashes = await store.cachedContentHashes()
        let refs = await store.cachedPhotoRefs()

        #expect(hashes.count == count, "ページの継ぎ目で落ちている: \(hashes.count)/\(count)")
        #expect(refs.count == count)
        #expect(await store.itemIndexBuildsForTesting == 1, "ページごとに作り直している")
    }

    /// ADR-119: 「1 回ぶんに見える呼び出し」が全列の実体化になっていないこと。**回数で見る**。
    @Test("射影は全列を実体化しない")
    func projectionDoesNotMaterializeAllColumns() async {
        let items = (0..<200).map { item("/p\($0).jpg", hash: "h\($0)") }
        let store = await store(items)
        let materializedBefore = await store.materializeCallsForTesting

        let hashes = await store.cachedContentHashes()

        #expect(hashes.count == items.count, "取りこぼしている")
        #expect(await store.itemIndexBuildsForTesting == 1, "1 回で作れていない")
        #expect(await store.materializeCallsForTesting == materializedBefore, """
            hash を取るために表示用の全件ロード（`cachedItems`）を通している。
            """)
    }
}
#endif
