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
/// ⚠️ **`.serialized`**（2026-09-26）。ここは実時間で「何回走ったか」を数えるテストなので、
/// 並列に走らせると**互いの CPU を奪ってループの壁時計が伸び**、回数の上限を超える。
/// 実際に踏んだ——バースト側の待ちを 0.6 秒から 2.5 秒へ延ばしたら、同時に走る背面側の
/// ループが伸びて 1 秒間隔の区間が 3 つ入り、`materialized → 3` で CI が落ちた。
/// 時間を測るテストは、他のテストと時間を共有してはいけない。
@Suite("DropboxPhotoStore の反映は合流する", .serialized)
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
        // ⚠️ **間隔を固定する**（CI が赤かった原因・2026-09-26）。本番の間隔は
        // 「直近の作り直しの 4 倍」（ADR-224 / diagnostics-92）なので、**遅いマシンでは
        // 自分で伸びる**。CI（macos-15）では 1 回目の作り直しが重く、間隔が数秒へ伸びて
        // 下の待ちでは最終反映が間に合わず、`items.count → 4` で落ちていた
        // （`materialized == 1` は通るので「まとめすぎ」に見えて紛らわしい）。
        // 間隔そのものは `intervalScalesWithCost` が純ロジックとして見ているので、
        // ここは**まとめる挙動だけ**を見る。
        store.refreshIntervalOverrideForTesting = 0.05
        // 静かの窓は、1 回の書き込みが遅い環境でも「変化の合間」と誤認されない長さにする。
        store.quietWindow = 1.0
        let before = await cache.materializeCallsForTesting

        // バックアップ中と同じ形: 変化が立て続けに届く。
        // ⚠️ **間に sleep を挟まない**。挟むと「変化の間隔 > 静かの窓」が
        // マシンの速さで決まってしまい、速い手元では通って遅い CI で落ちる。
        for i in 1...10 {
            await cache.applyDelta(accountId: "acct-burst",
                                   added: [DropboxFileItem(path: "/b/\(i).jpg", name: "\(i).jpg",
                                                           contentHash: "h\(i)")],
                                   removed: [], newCursor: "c\(i)")
            store.refreshItemsFromCacheSoon()
        }
        // 静かになってから走る（窓 1.0 秒＋余裕）。
        try await Task.sleep(nanoseconds: 2_500_000_000)

        let materialized = await cache.materializeCallsForTesting - before
        // ⚠️ `== 1` ではなく `<= 2`。窓が満ちた時点で走るのは**正しい挙動**で、遅い環境では
        // バースト中に 1 回入り得る。見たいのは「変化 1 回につき 1 回」になっていないこと
        // （実機では 73,936 行 × 21 回＝27 秒になった）。10 回に対して 2 回までなら
        // まとまっていると言える。
        #expect(materialized <= 2, """
            変化 10 回で実体化が \(materialized) 回走った。静かになるまでまとめていない
            （実機では 73,936 行 × 21 回＝27 秒になった）。
            """)
        #expect(materialized >= 1, "1 回も反映されていない（一覧が永久に古いまま）")
        #expect(store.items.count == 11, "まとめた結果が最新を反映していない")
    }

    /// ⚠️ **合流は「同じ版を読んでいるとき」だけ正しい**（ADR-230・データ落ち）。
    ///
    /// 走っている反映は「始めた時点のスナップショット」しか持たない。こちらが呼ばれたのは
    /// その後に版が進んだからなのに、無条件に合流すると**進んだぶんが一覧に出ないまま確定**する。
    /// しかも `lastReflectedRevision` が古い版で更新されるので、次の周期でも「変わっていない」と
    /// 判断されて**アプリを再起動するまで直らない**（初回同期の最後の数千枚・
    /// バックアップ直後の数枚がこれで消えていた）。
    ///
    /// 実際の競合はアクターの割り込み順で決まる＝壁時計では再現できないので、規則を固定する。
    @Test("合流してよいのは、合流先がこちらの版以上を反映したときだけ")
    func joinsOnlyWhenTheInFlightReflectIsCurrent() {
        typealias Store = DropboxPhotoStore
        #expect(Store.canJoinReflect(reflected: 7, wanted: 7), "同じ版なら合流してよい")
        #expect(Store.canJoinReflect(reflected: 9, wanted: 7), "先に進んでいるなら当然よい")
        #expect(!Store.canJoinReflect(reflected: 6, wanted: 7),
                "古い版しか読んでいない反映へ合流している（進んだぶんが落ちる）")
        // 中断（リセット・アカウント切替）は**何も反映していない**ので、合流は必ず誤り。
        #expect(!Store.canJoinReflect(reflected: nil, wanted: 0))
        #expect(!Store.canJoinReflect(reflected: nil, wanted: 7))
        // 合流を諦めて自分で反映するまでの回数に、上限があること（無限に待たない）。
        #expect(Store.maxReflectJoins >= 1 && Store.maxReflectJoins <= 5)
    }

    /// 間引きの間隔は**作り直しの実測時間から決まる**（純ロジック・実機ログ diagnostics-92）。
    ///
    /// ⚠️ 前面 0.4 秒固定では、バックアップ中の delta（3 秒おき）に対して**毎回**作り直していた
    /// ——3 分で 40 回・1 回 1.2〜2.1 秒。小さなライブラリは速いまま、大きいライブラリは自分で
    /// 空けるようにする。
    @Test("間隔は直近の作り直しの 4 倍（前面・背面・初回同期の下限つき）")
    func intervalScalesWithCost() {
        typealias Store = DropboxPhotoStore
        // 小さいライブラリ（作り直し 10ms）＝従来どおり素早く反映。
        #expect(Store.refreshInterval(lastRefreshSeconds: 0.01, isActive: true, isInitialSync: false)
                == Store.cacheRefreshIntervalForTesting)
        // 9.9 万件（1.5 秒）＝ 6 秒空ける。
        #expect(Store.refreshInterval(lastRefreshSeconds: 1.5, isActive: true, isInitialSync: false) == 6)
        // 頭打ち（前面で古いままになりすぎない）。
        #expect(Store.refreshInterval(lastRefreshSeconds: 30, isActive: true, isInitialSync: false)
                == Store.maxRefreshInterval)
        // 背面は誰も見ていないので下限 30 秒（ADR-224）。
        #expect(Store.refreshInterval(lastRefreshSeconds: 1.5, isActive: false, isInitialSync: false)
                == Store.backgroundRefreshInterval)
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
        let interval: TimeInterval = 1.0
        store.refreshIntervalOverrideForTesting = interval   // 背面の「30 秒に 1 回」をテスト用に 1 秒へ
        BackgroundYield.setScenePhase(.background)
        defer { BackgroundYield.setScenePhase(.active) }
        let before = await cache.materializeCallsForTesting

        // 実機と同じ形: 0.15 秒おきに変化が届く（無風 0.05 秒は毎回満たす）。
        let startedAt = Date()
        for i in 1...8 {
            await cache.applyDelta(accountId: "acct-bg",
                                   added: [DropboxFileItem(path: "/g/\(i).jpg", name: "\(i).jpg",
                                                           contentHash: "h\(i)")],
                                   removed: [], newCursor: "c\(i)")
            store.refreshItemsFromCacheSoon()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let elapsed = Date().timeIntervalSince(startedAt)

        let materialized = await cache.materializeCallsForTesting - before
        // ⚠️ **上限は経過時間から導く**（2026-09-26・CI が赤かった原因）。
        // 「1.2 秒だから 2 回まで」と書いていたが、**ループの壁時計はマシンの速さで決まる**
        // ——CI では 8 回の書き込みが延びて 1 秒の区間が 3 つ入り、正しい挙動（1 秒に 1 回）
        // なのに落ちていた。見たいのは「変化のたびに走っていないこと」なので、
        // 経過時間に入る区間の数＋端の 1 回を上限にする。
        let allowed = Int(ceil(elapsed / interval)) + 1
        #expect(materialized <= allowed, """
            \(String(format: "%.2f", elapsed)) 秒の間に作り直しが \(materialized) 回走った
            （上限 \(interval) 秒に 1 回＝許容 \(allowed) 回）。
            無風だけを見ていると、実機のように 3 秒おきの変化で毎回走る。
            """)
        // ⚠️ 変化 8 回に対して「回数で抑えている」ことも押さえる（上限が経過時間で伸びても、
        // 変化の数ぶん走るようになったら退行）。
        #expect(materialized < 8, "変化 8 回に対して \(materialized) 回＝抑えられていない")
        #expect(materialized >= 1, "背面でも最低 1 回は反映すること（解析候補が古いままになる）")
    }
}
#endif
