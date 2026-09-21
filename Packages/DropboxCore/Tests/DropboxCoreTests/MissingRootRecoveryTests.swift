#if canImport(UIKit)
import DropboxTestSupport
import Foundation
import Testing
@testable import DropboxCore

/// **同期ルートそのものが消えたとき**に立ち直れるか（diagnostics-82）。
///
/// 実機で起きた形: 家族の共有フォルダが Dropbox 上から無くなり、`list_folder/continue` が
/// `path/not_found` を返し続けた。アプリはそれを一時エラーとして扱い、30 秒ごとに
/// 18 日間投げ直した。差分は二度と届かないので、そのフォルダのキャッシュ 8,513 行は
/// **開けない写真として一覧に残り続けた**（タップすると本体取得が 409＝「ファイルがありません」）。
@Suite("消えた同期ルートからの立ち直り")
@MainActor
struct MissingRootRecoveryTests {

    private let root = "/Family"

    @MainActor private final class Recorder {
        var states: [DropboxPhotoStore.SyncState] = []
    }

    private func makeEngine(_ server: FakeDropboxServer, cache: DropboxCacheStore,
                            recorder: Recorder) -> DropboxSyncEngine {
        DropboxSyncEngine(
            apiClient: DropboxAPIClient(httpClient: server, tokenProvider: FakeTokenProvider()),
            cache: cache, onCacheUpdated: { _ in },
            onStateChanged: { recorder.states.append($0) })
    }

    private func waitUntil(_ timeout: TimeInterval = 6,
                           _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cachedCount(_ cache: DropboxCacheStore) async -> Int {
        await cache.cachedItems(accountId: "acc").count
    }

    /// ⚠️ **これが「ファイルがありません」の正体**。ルートが消えたのに行が残ると、
    /// 一覧には出るのに開けない写真になる。掃除しに来るものは他に無い
    /// （クラウドの一覧を取り直すのは初回同期のときだけ）。
    @Test("ルートが消えたら、そのルートのキャッシュを落として止まる")
    func dropsCacheWhenRootDisappears() async {
        let server = FakeDropboxServer()
        await server.seed(root, hash: "", isFolder: true)
        for index in 0..<3 {
            await server.upload(path: "\(root)/p\(index).jpg", data: Data("photo-\(index)".utf8))
        }
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedCount(cache) == 3 }

        // Dropbox 側でフォルダごと消える（共有の解除・Web UI での削除）。
        await server.removeFolder(root)

        await waitUntil { await self.cachedCount(cache) == 0 }
        engine.stop()

        let count = await cachedCount(cache)
        #expect(count == 0,
                """
                消えたルートのキャッシュが \(count) 件残っている。
                一覧には出るのに開けない写真になる（実機の「ファイルがありません」）。
                """)
    }

    /// ⚠️ **死んだカーソルを残さない**。残すと次回起動も poll へ直行して同じ 409 を踏み、
    /// 一覧の取り直し（＝掃除）に入る道が塞がれる。
    /// 「30 秒ごとに投げ直さない」ことそのものは待ち時間が長すぎて単体テストで測れないので、
    /// ここでは**やり直しの前提が消えていること**を見る（実機での再発は device-verification Z6）。
    @Test("消えたルートのカーソルを捨てる（次回起動が同じ 409 を踏まない）")
    func discardsCursorOfMissingRoot() async {
        let server = FakeDropboxServer()
        await server.seed(root, hash: "", isFolder: true)
        await server.upload(path: "\(root)/p0.jpg", data: Data("photo".utf8))
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedCount(cache) == 1 }
        let scope = "acc|" + root.lowercased()
        #expect(await cache.syncStateInfo(accountId: scope)?.cursor != nil, "前提: カーソルがある")

        await server.removeFolder(root)
        await waitUntil { await self.cachedCount(cache) == 0 }
        engine.stop()

        let cursor = await cache.syncStateInfo(accountId: scope)?.cursor
        #expect(cursor == nil,
                """
                消えたルートのカーソルが残っている（\(cursor ?? "nil")）。
                次の起動も poll へ直行し、同じ 409 を踏み続ける。
                """)
    }
}
#endif
