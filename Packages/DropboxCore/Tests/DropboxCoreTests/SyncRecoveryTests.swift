#if canImport(UIKit)
import DropboxTestSupport
import Foundation
import Testing
@testable import DropboxCore

/// **同期が壊れ方から立ち直れるか**。偽 Dropbox に足した異常（カーソル失効・遅い応答・
/// 時計のずれ）を使って、実機でしか起きないと思われていた状況を再現する。
@Suite("同期の立ち直り（カーソル失効・遅延）")
@MainActor
struct SyncRecoveryTests {

    private let root = "/Photos"

    private func seeded(_ server: FakeDropboxServer, count: Int) async {
        await server.seed(root, hash: "", isFolder: true)
        for index in 0..<count {
            await server.upload(path: "\(root)/p\(index).jpg", data: Data("photo-\(index)".utf8))
        }
    }

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

    /// ⚠️ **カーソルの失効**（Dropbox が `reset` を返す）。本物は稀に返し、そのときアプリは
    /// **初回同期からやり直す**必要がある。やり直せないと、以後の変更が永久に届かない。
    /// この経路は今まで一度も試せていなかった（台本どおりのスタブでは作れない）。
    @Test("カーソルが失効しても、取り直して追いつく")
    func recoversFromCursorReset() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 3)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedCount(cache) == 3 }

        // Dropbox 側でカーソルが失効し、そのあいだに 1 枚増える。
        // ⚠️ **失効は恒久的**（本物のカーソルは二度と有効にならない）。ここで元に戻さないのは、
        // 「投げ直せばそのうち通る」という偽の前提でテストを通さないため。
        await server.expireCursors()
        await server.upload(path: "\(root)/after-reset.jpg", data: Data("new".utf8))

        await waitUntil { await self.cachedCount(cache) == 4 }
        engine.stop()

        let count = await cachedCount(cache)
        let dump = await server.dump()
        #expect(count == 4,
                """
                カーソル失効から立ち直れていない（\(count) 件）。
                以後の変更が永久に届かない＝新しい写真が出てこない状態になる。
                サーバーの中身:
                \(dump)
                """)
    }

    /// 応答が遅くても、初回同期は完走すること（途中で諦めない）。
    @Test("応答が遅くても初回同期は完走する")
    func slowResponsesStillComplete() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 4)
        await server.setPageSize(2)
        await server.setResponseDelay(milliseconds: 30)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedCount(cache) == 4 }
        engine.stop()

        #expect(await cachedCount(cache) == 4, "遅い応答で取りこぼしている")
    }

    /// ⚠️ **回数で見る**（ADR-119）。初回同期が終わったあと、変化が無い間に
    /// `list_folder` を何度も投げ直していないこと（投げていれば通信も電池も無駄になる）。
    @Test("落ち着いた後は、一覧を投げ直さない")
    func idleDoesNotRelist() async {
        let server = FakeDropboxServer()
        await seeded(server, count: 3)
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [root])
        await waitUntil { await self.cachedCount(cache) == 3 }
        let afterInitial = await server.callCounts()["files/list_folder"] ?? 0

        try? await Task.sleep(for: .milliseconds(300))
        engine.stop()

        let final = await server.callCounts()["files/list_folder"] ?? 0
        let transcript = await server.transcript()
        #expect(final == afterInitial,
                """
                変化が無いのに一覧を \(final - afterInitial) 回投げ直している。
                \(transcript)
                """)
    }
}
#endif
