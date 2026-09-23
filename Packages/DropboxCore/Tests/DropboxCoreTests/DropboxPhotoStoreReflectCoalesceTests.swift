#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// キャッシュ反映の**合流**（同時に来ても全列の実体化は 1 回）。
///
/// ⚠️ 2 度踏んだ罠（diagnostics-38 → 65/66）。73k 行の実体化＋値型生成は 1 秒級・メモリも積む。
/// 1 度目の対処は `loadItems()` 側にだけ合流を置いたので、**定期の `refreshItemsFromCache()`
/// はそこを素通り**し、起動直後に 2 回走る状態が残っていた（`cache.fetchItems` 1109ms + 1012ms）。
/// 合流は呼び出し口ではなく反映関数そのものに置く——このテストは「別々の入口から同時に来ても
/// 実体化は 1 回」を固定する。
@Suite("DropboxPhotoStore の反映は合流する")
@MainActor
struct DropboxPhotoStoreReflectCoalesceTests {

    private func makeStore(cache: DropboxCacheStore, accountId: String = "acct-coalesce") -> DropboxPhotoStore {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        auth.credential = DropboxCredential(accessToken: "t", refreshToken: nil, expiresAt: nil,
                                            accountId: accountId, connectedAt: Date(),
                                            lastRefreshedAt: nil)
        return DropboxPhotoStore(auth: auth, cache: cache)
    }

    @Test("別々の入口から同時に来ても、全列の実体化は 1 回だけ")
    func concurrentReflectsCoalesceIntoOneMaterialization() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let items = (0..<50).map {
            DropboxFileItem(path: "/coalesce/\($0).jpg", name: "\($0).jpg", contentHash: "h\($0)")
        }
        await cache.applyDelta(accountId: "acct-coalesce", added: items, removed: [], newCursor: "c1")
        let before = await cache.materializeCallsForTesting
        let store = makeStore(cache: cache)

        // 起動直後に実際に起きる形: 初回ロードと定期リフレッシュがほぼ同時に走る。
        async let load: Void = store.loadItems()
        async let refresh: Void = store.refreshItemsFromCache()
        _ = await (load, refresh)

        let materialized = await cache.materializeCallsForTesting - before
        #expect(materialized == 1, "実体化が \(materialized) 回走った（合流していない）")
        #expect(store.items.count == items.count, "合流した側が空を掴んでいる")
    }

    /// ⚠️ **変化が続いている間は反映しない**（実機ログ diagnostics-87）。
    /// バックアップ中はアップロードのたびに delta が届き（2 分 15 秒で 38 回）、以前の
    /// 「直近の反映から 0.4 秒空いていれば走る」では**変化のたびに走り直して**いた
    /// ——73,936 行の実体化が 21 回・合計 27 秒。静かになってから 1 回で足りる。
    @Test("変化が連続している間は、反映を 1 回にまとめる")
    func burstOfChangesCoalescesIntoOneRefresh() async throws {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acct-burst",
                               added: [DropboxFileItem(path: "/b/0.jpg", name: "0.jpg", contentHash: "h0")],
                               removed: [], newCursor: "c0")
        let store = makeStore(cache: cache, accountId: "acct-burst")
        store.quietWindow = 0.20          // テストは短く
        let before = await cache.materializeCallsForTesting

        // バックアップ中と同じ形: 変化が立て続けに届く。
        for i in 1...10 {
            await cache.applyDelta(accountId: "acct-burst",
                                   added: [DropboxFileItem(path: "/b/\(i).jpg", name: "\(i).jpg",
                                                           contentHash: "h\(i)")],
                                   removed: [], newCursor: "c\(i)")
            store.refreshItemsFromCacheSoon()
            try await Task.sleep(nanoseconds: 50_000_000)   // 0.05 秒間隔（静かにならない）
        }
        // 静かになってから 1 回走る。
        try await Task.sleep(nanoseconds: 600_000_000)

        let materialized = await cache.materializeCallsForTesting - before
        #expect(materialized == 1, """
            変化 10 回で実体化が \(materialized) 回走った。静かになるまでまとめていない
            （実機では 73,936 行 × 21 回＝27 秒になった）。
            """)
        #expect(store.items.count == 11, "まとめた結果が最新を反映していない")
    }
}
#endif
