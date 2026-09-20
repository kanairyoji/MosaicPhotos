#if canImport(UIKit)
import DropboxTestSupport
import Foundation
import Testing
@testable import DropboxCore

/// **同期は収束するか**——状態を持つ偽 Dropbox を相手に、初回同期と差分を通しで走らせる。
///
/// ## なぜ通しで見るか
/// 既存の `DropboxSyncEngineTests` は「どの分岐に入るか」を台本どおりの応答で確かめている。
/// しかし実機で起きた問題は**分岐ではなく収束**の側だった——初回同期が終わらない、
/// 消したはずの写真が残る、変わっていないのに全行を書き直す。
/// どれも「サーバーの状態が変わり、それを取り込む」流れを繰り返さないと出てこない。
@Suite("同期の収束（初回 → 差分）")
@MainActor
struct SyncConvergenceTests {

    private let root = "/Photos"

    private func seeded(_ server: FakeDropboxServer, count: Int) async {
        await server.seed(root, hash: "", isFolder: true)
        for index in 0..<count {
            await server.upload(path: "\(root)/p\(index).jpg", data: Data("photo-\(index)".utf8))
        }
    }

    @MainActor
    private final class StateRecorder {
        var states: [DropboxPhotoStore.SyncState] = []
    }

    private func makeEngine(_ server: FakeDropboxServer, cache: DropboxCacheStore,
                            recorder: StateRecorder) -> DropboxSyncEngine {
        DropboxSyncEngine(
            apiClient: DropboxAPIClient(httpClient: server, tokenProvider: FakeTokenProvider()),
            cache: cache,
            onCacheUpdated: { _ in },
            onStateChanged: { recorder.states.append($0) })
    }

    /// 条件が満たされるまで待つ（上限つき・満たされたら即戻る）。
    private func waitUntil(_ timeout: TimeInterval = 5,
                           _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cachedPaths(_ cache: DropboxCacheStore) async -> [String] {
        await cache.cachedItems(accountId: "acc").map(\.path).sorted()
    }

    @Test("初回同期でサーバーのファイルが全部キャッシュに入る")
    func initialSyncPullsEverything() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 5)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = StateRecorder()
        let engine = makeEngine(server, cache: cache, recorder: recorder)

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedPaths(cache).count == 5 }
        engine.stop()

        let paths = await cachedPaths(cache)
        #expect(paths.count == 5, "初回同期が全件を取り込めていない: \(paths)")
    }

    /// ⚠️ **ページを跨いでも取りこぼさない**。1 ページ目だけ取り込んで終わると、
    /// 利用者からは「一部の写真が出てこない」に見える（原因が掴みにくい形）。
    @Test("ページが分かれていても、初回同期は全件そろう")
    func initialSyncCrossesPages() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 7)
        await server.setPageSize(2)              // 4 ページに分かれる
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: StateRecorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedPaths(cache).count == 7 }
        engine.stop()

        let paths = await cachedPaths(cache)
        #expect(paths.count == 7, "ページを読み切れていない: \(paths.count) 件")
    }

    /// ⚠️ **本命**: サーバー側の増減が、差分（longpoll → continue）で反映されること。
    /// 追加だけ反映して削除を取りこぼすと、消えた写真がいつまでも一覧に残る。
    @Test("同期を続けたまま、サーバー側の追加と削除が反映される")
    func deltaReflectsAdditionsAndRemovals() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 3)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: StateRecorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedPaths(cache).count == 3 }

        // 他端末が 1 枚追加した。
        await server.upload(path: "\(root)/new.jpg", data: Data("new".utf8))
        await waitUntil { await self.cachedPaths(cache).contains("\(root.lowercased())/new.jpg") }
        let afterAdd = await cachedPaths(cache)
        #expect(afterAdd.count == 4, "追加が差分で入ってこない: \(afterAdd)")

        // 他端末が 1 枚消した。
        await server.remove("\(root)/p0.jpg")
        await waitUntil { await self.cachedPaths(cache).count == 3 }
        engine.stop()

        let final = await cachedPaths(cache)
        #expect(!final.contains("\(root.lowercased())/p0.jpg"),
                "削除が差分で反映されない（消えた写真が一覧に残る）: \(final)")
    }

    /// ⚠️ **変わっていないのに書き直さない**（実機で 11 万行の書き直し・1.07GB の警告を出した形）。
    /// 差分が空の回は、キャッシュの版（`itemsRevision`）が進まないこと。
    @Test("変化が無い回は、キャッシュを書き直さない")
    func idlePollsDoNotRewriteTheCache() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 3)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: StateRecorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedPaths(cache).count == 3 }
        let settled = await cache.currentItemsRevision()

        // 何も起きない時間を過ごす（longpoll は「変更なし」を返し続ける）。
        try? await Task.sleep(for: .milliseconds(300))
        engine.stop()

        let revision = await cache.currentItemsRevision()
        #expect(revision == settled,
                "変化が無いのにキャッシュを書き直している（ディスク書き込みの山になる）")
    }
}
#endif
