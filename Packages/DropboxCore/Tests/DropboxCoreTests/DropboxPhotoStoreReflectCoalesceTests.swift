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

    private func makeStore(cache: DropboxCacheStore) -> DropboxPhotoStore {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        auth.credential = DropboxCredential(accessToken: "t", refreshToken: nil, expiresAt: nil,
                                            accountId: "acct-coalesce", connectedAt: Date(),
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
}
#endif
