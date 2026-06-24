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
#endif
