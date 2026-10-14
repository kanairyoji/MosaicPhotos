import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// 共有の反映は、始めた時点のトークンを使い回さない（diagnostics-110）。
///
/// 実機では反映を始めた直後にプロセスが 6 時間止められ、戻ったときにはトークンの期限が
/// 過ぎていた——続きの要求が 401（`create_folder failed (401)`）で、その回は丸ごと見送り。
/// ここでは「始めたときに受け取ったトークンは、次に使うときには期限切れ」を模す。
@MainActor
@Suite("共有の反映: トークンは区切りごとに取り直す")
struct ShareTokenReissueTests {

    /// 呼ばれるたびに新しいトークンを出す（`tok-1`, `tok-2`, …）。
    final class CountingTokenProvider: AccessTokenProvider, @unchecked Sendable {
        var calls = 0
        func freshAccessToken() async throws -> String {
            calls += 1
            return "tok-\(calls)"
        }
    }

    /// 期限切れのトークンには 401 を返す。
    /// - 始めたときのトークン（`tok-1`）は最初から期限切れ（台帳を開く間に止められた）。
    /// - 共有ルートの一覧を通した直後に、そのトークンも期限切れにする（一覧の後に止められた）。
    /// ⚠️ 2 つ目が無いと、セットごとの取り直しを外しても通る（一覧の前の 1 回だけで足りてしまう）。
    final class ExpiringTokens: HTTPClient, @unchecked Sendable {
        let inner: FakeDropboxServer
        private let lock = NSLock()
        private var expired: Set<String> = ["Bearer tok-1"]
        private var rejected = 0
        private var accepted = 0
        init(inner: FakeDropboxServer) { self.inner = inner }
        var counts: (rejected: Int, accepted: Int) { lock.withLock { (rejected, accepted) } }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let isExpired = lock.withLock { expired.contains(auth) }
            if isExpired {
                lock.withLock { rejected += 1 }
                let body = Data(#"{"error_summary":"expired_access_token/.."}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 401,
                                              httpVersion: nil, headerFields: nil)!)
            }
            lock.withLock { accepted += 1 }
            let result = try await inner.data(for: request)
            if request.url?.path == "/2/files/list_folder",
               (result.1 as? HTTPURLResponse)?.statusCode == 200 {
                lock.withLock { _ = expired.insert(auth) }
            }
            return result
        }
    }

    @Test("始めたときのトークンが期限切れでも、反映の要求は取り直したトークンで出る")
    func requestsUseReissuedToken() async {
        let defaults = TestDefaults.scratch("share-token-reissue")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set("/MosaicPhotos", forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        let path = "/mosaicphotos/backup/2020/p0.jpg"
        await server.seed(path, hash: "h0")
        await store.upsertRecord(dropboxPath: path, localIdentifier: "p0",
                                 filename: "p0.jpg", creationDate: nil, contentHash: "h0",
                                 people: [], albums: [], isFavorite: false)
        // ⚠️ セットは台帳へ直接作る（`createSet` が予約する反映と、この回が重ならないように）。
        let set = await store.createShareSet(name: "Family", folderName: "Family")
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-p0"])
        // 共有ルートを在る状態にする（一覧が通る＝「一覧の後に止められた」を作れる）。
        let shareRoot = ShareSettingsKeys.currentShareRoot(defaults).lowercased()
        await server.seed("\(shareRoot)/family/old.jpg", hash: "h-old")
        let client = ExpiringTokens(inner: server)
        let tokens = CountingTokenProvider()
        let engine = ShareSyncEngine(tokenProvider: tokens, storeProvider: { store },
                                     httpClient: client, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.networkAllowed = { true }

        await engine.syncNow()

        let counts = client.counts
        // ⚠️ 前提: この fixture は通信する（0 往復だと「古いトークンで投げていない」が空で通る）。
        // ⚠️ 一覧の後にもう 1 往復以上あること（無いとセットの段の取り直しを測れない）。
        #expect(counts.accepted >= 2, "一覧の後に往復が無い（fixture が何も測っていない）: \(counts)")
        #expect(counts.rejected == 0, "期限切れのトークンを使い回した（\(counts.rejected) 往復が 401）")
        #expect(engine.lastError == nil, "取り直したのに反映が失敗した: \(String(describing: engine.lastError))")
    }
}
