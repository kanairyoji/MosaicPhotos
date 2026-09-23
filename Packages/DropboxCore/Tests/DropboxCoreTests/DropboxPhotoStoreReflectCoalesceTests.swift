#if canImport(UIKit)
import Foundation
import MosaicSupport
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

    /// ⚠️ **無風だけでは足りない**（実機ログ diagnostics-89）。バックアップ中の delta は
    /// **3 秒おき**に届くので、無風 1.5 秒を毎回満たして作り直しが 5 分で 60 回・102 秒になった。
    /// 背面は誰も一覧を見ていないので、**回数の上限**（既定 30 秒に 1 回）で抑える。
    @Test("背面では、変化が 3 秒おきに来ても作り直しは上限まで")
    func backgroundRefreshIsRateLimited() async throws {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acct-bg",
                               added: [DropboxFileItem(path: "/g/0.jpg", name: "0.jpg", contentHash: "h0")],
                               removed: [], newCursor: "c0")
        let store = makeStore(cache: cache, accountId: "acct-bg")
        store.quietWindow = 0.05
        store.refreshIntervalOverrideForTesting = 1.0   // 背面の「30 秒に 1 回」をテスト用に 1 秒へ
        BackgroundYield.setScenePhase(.background)
        defer { BackgroundYield.setScenePhase(.active) }
        let before = await cache.materializeCallsForTesting

        // 実機と同じ形: 0.15 秒おきに変化が届く（無風 0.05 秒は毎回満たす）。
        for i in 1...8 {
            await cache.applyDelta(accountId: "acct-bg",
                                   added: [DropboxFileItem(path: "/g/\(i).jpg", name: "\(i).jpg",
                                                           contentHash: "h\(i)")],
                                   removed: [], newCursor: "c\(i)")
            store.refreshItemsFromCacheSoon()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let materialized = await cache.materializeCallsForTesting - before
        #expect(materialized <= 2, """
            1.2 秒の間に作り直しが \(materialized) 回走った（上限 1 秒に 1 回のはず）。
            無風だけを見ていると、実機のように 3 秒おきの変化で毎回走る。
            """)
        #expect(materialized >= 1, "背面でも最低 1 回は反映すること（解析候補が古いままになる）")
    }
}
#endif
