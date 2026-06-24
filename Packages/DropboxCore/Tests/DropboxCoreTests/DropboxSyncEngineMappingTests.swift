#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// `DropboxSyncEngine` が list_folder の各エントリを `DropboxFileItem` に変換する規則を検証する。
/// （撮影日時 time_taken ?? client_modified、media_info からの座標、非画像・削除の扱い）
/// 変換結果はキャッシュ経由で `cachedItems` から読めるため、それを突き合わせる。
@Suite("DropboxSyncEngine mapping")
@MainActor
struct DropboxSyncEngineMappingTests {

    @MainActor
    final class StateRecorder {
        var states: [DropboxPhotoStore.SyncState] = []
    }

    /// list_folder に指定 JSON を返し、get_latest_cursor/longpoll/continue は polling 到達用の最小応答を返す。
    private func stub(listFolderJSON: String) -> StubHTTPClient {
        StubHTTPClient { req in
            let url = req.url?.absoluteString ?? ""
            let json: String
            if url.contains("get_latest_cursor") {
                json = #"{"cursor":"baseline"}"#
            } else if url.contains("longpoll") {
                json = #"{"changes":false}"#
            } else if url.contains("list_folder/continue") {
                json = #"{"entries":[],"cursor":"c2","has_more":false}"#
            } else {
                json = listFolderJSON
            }
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func runInitialSync(listFolderJSON: String) async -> DropboxCacheStore {
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = StateRecorder()
        let apiClient = DropboxAPIClient(httpClient: stub(listFolderJSON: listFolderJSON),
                                         tokenProvider: StubTokenProvider())
        let engine = DropboxSyncEngine(
            apiClient: apiClient, cache: cache,
            onCacheUpdated: {}, onStateChanged: { recorder.states.append($0) })
        engine.start(accountId: "acc")
        await waitUntil { recorder.states.contains(.polling) }
        engine.stop()
        return cache
    }

    private func iso(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

    @Test("画像ファイルのみ取り込み、time_taken 優先・media_info から座標を反映する")
    func mapsLocatedImage() async {
        let json = """
        {"entries":[
          {".tag":"file","name":"a.jpg","path_lower":"/trip/a.jpg","content_hash":"h1",
           "client_modified":"2020-01-01T00:00:00Z",
           "media_info":{"metadata":{"location":{"latitude":35.5,"longitude":139.5},
                                     "time_taken":"2019-06-15T12:00:00Z"}}}
        ],"cursor":"c1","has_more":false}
        """
        let cache = await runInitialSync(listFolderJSON: json)
        let items = await cache.cachedItems(accountId: "acc")
        let a = try! #require(items.first { $0.path == "/trip/a.jpg" })
        #expect(a.captureDate == iso("2019-06-15T12:00:00Z"))   // time_taken 優先
        #expect(a.latitude == 35.5)
        #expect(a.longitude == 139.5)
        #expect(a.coordinate != nil)
    }

    @Test("time_taken が無ければ client_modified を撮影日時に使う")
    func fallsBackToClientModified() async {
        let json = """
        {"entries":[
          {".tag":"file","name":"b.jpg","path_lower":"/trip/b.jpg","client_modified":"2021-02-03T04:05:06Z"}
        ],"cursor":"c1","has_more":false}
        """
        let cache = await runInitialSync(listFolderJSON: json)
        let items = await cache.cachedItems(accountId: "acc")
        let b = try! #require(items.first { $0.path == "/trip/b.jpg" })
        #expect(b.captureDate == iso("2021-02-03T04:05:06Z"))
        #expect(b.coordinate == nil)   // media_info 無し → 座標なし
    }

    @Test("media_info が pending（metadata 無し）なら座標なし・client_modified を使う")
    func pendingMediaInfo() async {
        let json = """
        {"entries":[
          {".tag":"file","name":"c.jpg","path_lower":"/trip/c.jpg",
           "client_modified":"2022-03-03T00:00:00Z","media_info":{".tag":"pending"}}
        ],"cursor":"c1","has_more":false}
        """
        let cache = await runInitialSync(listFolderJSON: json)
        let items = await cache.cachedItems(accountId: "acc")
        let c = try! #require(items.first { $0.path == "/trip/c.jpg" })
        #expect(c.captureDate == iso("2022-03-03T00:00:00Z"))
        #expect(c.coordinate == nil)
    }

    @Test("非画像ファイルと deleted エントリは取り込まれない")
    func excludesNonImageAndDeleted() async {
        let json = """
        {"entries":[
          {".tag":"file","name":"a.jpg","path_lower":"/x/a.jpg","client_modified":"2020-01-01T00:00:00Z"},
          {".tag":"file","name":"notes.txt","path_lower":"/x/notes.txt","client_modified":"2020-01-01T00:00:00Z"},
          {".tag":"deleted","name":"gone.jpg","path_lower":"/x/gone.jpg"}
        ],"cursor":"c1","has_more":false}
        """
        let cache = await runInitialSync(listFolderJSON: json)
        let items = await cache.cachedItems(accountId: "acc")
        #expect(items.count == 1)
        #expect(items.first?.path == "/x/a.jpg")
    }
}
#endif
