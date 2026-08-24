#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// `DropboxAuthService` のトークン期限判定・リフレッシュ重複排除・資格情報の保存/復元を、
/// `DateProvider` / `HTTPClient` / `CredentialStore`（インメモリ）を注入して決定的に検証する。
@Suite("DropboxAuthService")
@MainActor
struct DropboxAuthServiceTests {

    private func makeAuth(
        now: Date,
        credential: DropboxCredential?,
        stub: StubHTTPClient
    ) -> (DropboxAuthService, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore(credential)
        let auth = DropboxAuthService(
            appKey: "key", redirectURI: "scheme://cb",
            httpClient: stub, dateProvider: FixedDateProvider(now),
            credentialStore: store
        )
        return (auth, store)
    }

    private func cred(
        access: String, refresh: String?, expiresAt: Date?, now: Date
    ) -> DropboxCredential {
        DropboxCredential(accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                          accountId: "acc", connectedAt: now, lastRefreshedAt: nil)
    }

    @Test("保存済み資格情報を init で復元し connected になる")
    func initLoadsCredential() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubHTTPClient(responder: StubHTTPClient.status(200))
        let (auth, _) = makeAuth(now: now, credential: cred(access: "saved", refresh: "rt", expiresAt: now.addingTimeInterval(3600), now: now), stub: stub)
        #expect(auth.connectionStatus == .connected)
        #expect(auth.credential?.accessToken == "saved")
    }

    @Test("未期限のトークンはネットワークなしでキャッシュを返す")
    func returnsCachedWhenNotExpired() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubHTTPClient(responder: StubHTTPClient.status(200))
        let (auth, _) = makeAuth(now: now, credential: cred(access: "cached", refresh: "rt", expiresAt: now.addingTimeInterval(3600), now: now), stub: stub)

        #expect(try await auth.freshAccessToken() == "cached")
        #expect(await stub.recordedRequests().isEmpty)
    }

    @Test("リフレッシュトークンなし（直接トークン）はそのまま返す")
    func directTokenPassthrough() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubHTTPClient(responder: StubHTTPClient.status(200))
        let (auth, _) = makeAuth(now: now, credential: cred(access: "direct", refresh: nil, expiresAt: nil, now: now), stub: stub)

        #expect(try await auth.freshAccessToken() == "direct")
        #expect(await stub.recordedRequests().isEmpty)
    }

    @Test("期限切れの同時要求はリフレッシュを1回だけ実行し、新トークンを保存する")
    func deduplicatesConcurrentRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubHTTPClient { req in
            let json = #"{"access_token":"new-token","expires_in":3600}"#
            return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let (auth, store) = makeAuth(now: now, credential: cred(access: "old", refresh: "rt", expiresAt: now.addingTimeInterval(-100), now: now), stub: stub)

        async let t1 = auth.freshAccessToken()
        async let t2 = auth.freshAccessToken()
        async let t3 = auth.freshAccessToken()
        let tokens = try await [t1, t2, t3]

        #expect(tokens == ["new-token", "new-token", "new-token"])
        #expect(await stub.recordedRequests().count == 1)        // 重複排除でリフレッシュは1回
        #expect(store.load()?.accessToken == "new-token")        // 新トークンが永続化された
    }

    @Test("disconnect で資格情報を消去し notConnected になる")
    func disconnectClearsStore() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubHTTPClient(responder: StubHTTPClient.status(200))
        let (auth, store) = makeAuth(now: now, credential: cred(access: "x", refresh: "rt", expiresAt: now.addingTimeInterval(3600), now: now), stub: stub)

        auth.disconnect()
        #expect(auth.connectionStatus == .notConnected)
        #expect(auth.credential == nil)
        #expect(store.load() == nil)
    }
}
// MARK: - 切断と進行中の往復（レビュー指摘）

/// ⚠️ トークン更新は往復に時間がかかる。その最中にユーザーが切断すると、以前は
/// 後から完了した更新が Keychain へ新しい資格情報を書き戻し、**操作に反してセッションが
/// 復活**していた。世代を照合して結果を捨てること。
@Suite("DropboxAuthService disconnect races")
@MainActor
struct DropboxAuthDisconnectTests {

    /// 応答を「テストが許可するまで」止めておける HTTP クライアント。
    private actor GatedHTTPClient: HTTPClient {
        private var didStart = false
        private var isReleased = false
        private var waiter: CheckedContinuation<Void, Never>?
        private let body: String

        init(body: String) { self.body = body }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            didStart = true
            if !isReleased {
                await withCheckedContinuation { waiter = $0 }
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }

        func started() -> Bool { didStart }
        func release() {
            isReleased = true
            waiter?.resume()
            waiter = nil
        }
    }

    @Test("更新中に切断したら、後から来た新トークンを保存しない")
    func disconnectDuringRefreshDiscardsResult() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = GatedHTTPClient(body: #"{"access_token":"new-token","expires_in":3600}"#)
        let store = InMemoryCredentialStore(DropboxCredential(
            accessToken: "old", refreshToken: "rt", expiresAt: now.addingTimeInterval(-100),
            accountId: "acc", connectedAt: now, lastRefreshedAt: nil))
        let auth = DropboxAuthService(appKey: "key", redirectURI: "scheme://cb",
                                      httpClient: client, dateProvider: FixedDateProvider(now),
                                      credentialStore: store)

        // 更新を開始し、往復の途中で止める。
        let refresh = Task { try? await auth.freshAccessToken() }
        while !(await client.started()) { await Task.yield() }

        auth.disconnect()
        await client.release()
        _ = await refresh.value

        #expect(auth.credential == nil, "切断したのに資格情報が復活した")
        #expect(store.stored == nil, "切断後に Keychain へ書き戻した")
        #expect(auth.connectionStatus == .notConnected)
    }

    @Test("切断は進行中の更新タスクをキャンセルする")
    func disconnectCancelsRefreshTask() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = GatedHTTPClient(body: #"{"access_token":"new-token","expires_in":3600}"#)
        let auth = DropboxAuthService(
            appKey: "key", redirectURI: "scheme://cb", httpClient: client,
            dateProvider: FixedDateProvider(now),
            credentialStore: InMemoryCredentialStore(DropboxCredential(
                accessToken: "old", refreshToken: "rt", expiresAt: now.addingTimeInterval(-100),
                accountId: "acc", connectedAt: now, lastRefreshedAt: nil)))

        let refresh = Task { try? await auth.freshAccessToken() }
        while !(await client.started()) { await Task.yield() }
        auth.disconnect()
        #expect(auth.refreshTask == nil, "進行中の更新タスクを手放していない")

        await client.release()
        _ = await refresh.value
    }

    /// 直接トークン投入も同じ。検証の往復中に切断されたら保存しない。
    @Test("直接トークンの検証中に切断したら保存しない")
    func disconnectDuringDirectTokenDiscardsResult() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let client = GatedHTTPClient(body: #"{"account_id":"acc"}"#)
        let store = InMemoryCredentialStore(nil)
        let auth = DropboxAuthService(appKey: "key", redirectURI: "scheme://cb",
                                      httpClient: client, dateProvider: FixedDateProvider(now),
                                      credentialStore: store)

        let task = Task { await auth.setDirectToken("typed-token") }
        while !(await client.started()) { await Task.yield() }
        auth.disconnect()
        await client.release()
        await task.value

        #expect(auth.credential == nil, "切断したのにトークンが適用された")
        #expect(store.stored == nil)
    }
}
#endif
