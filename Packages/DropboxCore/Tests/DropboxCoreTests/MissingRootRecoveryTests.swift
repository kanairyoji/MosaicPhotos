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

    /// ⚠️ **アカウント全体（root == ""）では掃除しない**（レビュー 2 周目）。
    /// 掃除の範囲は「このルートの配下」なので、root が空だと**キャッシュ全体**が対象になる。
    /// アカウントのルートは消えようがないから、そこで not_found が返るのは想定外の応答
    /// ——得るものが無いのに 8 万行を捨てることになる。
    @Test("アカウント全体を同期しているときは、not_found でキャッシュを捨てない")
    func doesNotWipeEverythingForTheAccountRoot() async {
        let server = FakeDropboxServer()
        for index in 0..<3 {
            await server.upload(path: "/p\(index).jpg", data: Data("photo-\(index)".utf8))
        }
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let engine = makeEngine(server, cache: cache, recorder: Recorder())

        engine.start(accountId: "acc", roots: [""])
        await waitUntil { await self.cachedCount(cache) == 3 }

        // 差分の取得だけが「そこに無い」と言ってくる（想定外の応答）。
        await server.inject(.init(endpoint: "list_folder/continue", effect: .status(409)))
        await server.upload(path: "/p9.jpg", data: Data("new".utf8))   // 差分を起こす
        // ⚠️ **時間ではなく「仕込みが実際に使われたこと」で待つ**。固定の待ちにしていたら、
        // 並列実行で込み合った回だけ差分取得まで届かず、**何も起きていないのに緑**になった
        //（単体で走らせると落ちる＝フレーキー）。ADR-119 の「空でも通る assert を書かない」。
        await waitUntil {
            await server.requestLog.contains { $0.contains("list_folder/continue") }
        }
        try? await Task.sleep(for: .milliseconds(100))   // 掃除が走るなら走り切る余地
        engine.stop()

        let count = await cachedCount(cache)
        #expect(count == 3, """
                アカウント全体のキャッシュを捨てた（残り \(count) 件）。
                ルートが空のとき、掃除の範囲は「配下」ではなく**全部**になる。
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
