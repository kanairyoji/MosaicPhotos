#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// `DropboxSyncEngine` の同期分岐（initialSync ↔ pollLoop）とキャンセルを、
/// list_folder 系レスポンスをスタブ化して検証する。「初回表示されない」調査で焦点になった分岐。
@Suite("DropboxSyncEngine")
@MainActor
struct DropboxSyncEngineTests {

    /// onStateChanged で渡される状態を記録する。
    @MainActor
    final class StateRecorder {
        var states: [DropboxPhotoStore.SyncState] = []
        var sawInitialSync: Bool {
            states.contains { if case .initialSync = $0 { return true }; return false }
        }
    }

    /// エンドポイント別に最小の有効レスポンスを返すルーティングスタブ。
    private func routingStub() -> StubHTTPClient {
        StubHTTPClient { req in
            let url = req.url?.absoluteString ?? ""
            let json: String
            if url.contains("get_latest_cursor") {
                json = #"{"cursor":"baseline"}"#
            } else if url.contains("longpoll") {
                json = #"{"changes":false}"#          // 変更なし → poll ループ継続
            } else {
                json = #"{"entries":[],"cursor":"c1","has_more":false}"#  // 空の list_folder(/continue)
            }
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func makeEngine(cache: DropboxCacheStore, stub: StubHTTPClient, recorder: StateRecorder) -> DropboxSyncEngine {
        let apiClient = DropboxAPIClient(httpClient: stub, tokenProvider: StubTokenProvider())
        return DropboxSyncEngine(
            apiClient: apiClient,
            cache: cache,
            onCacheUpdated: {},
            onStateChanged: { recorder.states.append($0) }
        )
    }

    @Test("カーソルが無ければ initialSync を実行し、完了後に polling へ入る")
    func noCursorRunsInitialSync() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = StateRecorder()
        let engine = makeEngine(cache: cache, stub: routingStub(), recorder: recorder)

        engine.start(accountId: "acc")
        await waitUntil { recorder.states.contains(.polling) }
        engine.stop()

        #expect(recorder.sawInitialSync)
        #expect(recorder.states.contains(.polling))
    }

    @Test("カーソルが有り、かつアイテムがあれば initialSync を飛ばして直接 polling に入る")
    func cursorWithItemsSkipsInitialSync() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        // 既存カーソル＋アイテム → syncLoop は pollLoop を選ぶ。
        let item = DropboxFileItem(path: "/a.jpg", name: "a.jpg")
        await cache.applyDelta(accountId: "acc", added: [item], removed: [], newCursor: "existing-cursor")
        let recorder = StateRecorder()
        let engine = makeEngine(cache: cache, stub: routingStub(), recorder: recorder)

        engine.start(accountId: "acc")
        await waitUntil { recorder.states.contains(.polling) }
        engine.stop()

        #expect(!recorder.sawInitialSync)
        #expect(recorder.states.contains(.polling))
    }

    @Test("カーソルは有るがアイテム0なら（キャッシュ不整合）initialSync をやり直して自己修復する")
    func cursorButEmptyReScans() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        // カーソルだけ有ってアイテム0 → 「接続済みなのに空のまま」になる状態を再現。
        await cache.applyDelta(accountId: "acc", added: [], removed: [], newCursor: "stale-cursor")
        let recorder = StateRecorder()
        let engine = makeEngine(cache: cache, stub: routingStub(), recorder: recorder)

        engine.start(accountId: "acc")
        await waitUntil { recorder.states.contains(.polling) }
        engine.stop()

        #expect(recorder.sawInitialSync)   // 再スキャンが走る
        #expect(recorder.states.contains(.polling))
    }

    @Test("stop() で poll ループが終了する")
    func stopEndsPolling() async {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        await cache.applyDelta(accountId: "acc", added: [], removed: [], newCursor: "existing-cursor")
        let recorder = StateRecorder()
        let engine = makeEngine(cache: cache, stub: routingStub(), recorder: recorder)

        engine.start(accountId: "acc")
        await waitUntil { recorder.states.contains(.polling) }
        engine.stop()

        // 停止後、ループ終了と最終状態の確定を十分待ってから、以降は増えない（暴走しない）ことを確認。
        try? await Task.sleep(nanoseconds: 300_000_000)
        let count = recorder.states.count
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.states.count == count)
    }
}
#endif
