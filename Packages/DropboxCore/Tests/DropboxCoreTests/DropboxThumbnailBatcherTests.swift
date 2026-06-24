#if canImport(UIKit)
import Foundation
import Testing
import UIKit
@testable import DropboxCore

/// `DropboxThumbnailBatcher` のバッチ集約・dedup・キャンセル耐性・異常系を、
/// ネットワークをスタブ化して検証する。サムネイル表示不具合の回帰ガード。
@Suite("DropboxThumbnailBatcher")
@MainActor
struct DropboxThumbnailBatcherTests {

    // MARK: - Fixtures

    private func makeAuth() -> DropboxAuthService {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "scheme://cb")
        // expiresAt=nil, refreshToken=nil → freshAccessToken はネットワークなしでトークンを返す。
        auth.setCredentialForTesting(DropboxCredential(
            accessToken: "test-token", refreshToken: nil, expiresAt: nil,
            accountId: "acc", connectedAt: Date(), lastRefreshedAt: nil
        ))
        return auth
    }

    private func makeBatcher(
        _ stub: StubHTTPClient,
        chunkSize: Int = 25,
        debounceNs: UInt64 = 5_000_000
    ) -> DropboxThumbnailBatcher {
        let apiClient = DropboxAPIClient(httpClient: stub, tokenProvider: makeAuth())
        return DropboxThumbnailBatcher(
            apiClient: apiClient,
            cache: DropboxCacheStore(isStoredInMemoryOnly: true),
            debounceNs: debounceNs,
            chunkSize: chunkSize
        )
    }

    private func item(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
    }

    /// バッチリクエストの entries に含まれるパス一覧を取り出す。
    private func paths(in request: URLRequest) -> [String] {
        struct Entry: Decodable { let path: String }
        struct Arg: Decodable { let entries: [Entry] }
        let arg = try? JSONDecoder().decode(Arg.self, from: request.httpBody ?? Data())
        return arg?.entries.map(\.path) ?? []
    }

    /// 記録リクエスト数が `untilCount` に達するまでポーリングで待つ。
    /// 並列 @MainActor テストの競合下でも安定するよう、固定 sleep ではなく結果駆動で待つ。
    private func pollRequests(_ stub: StubHTTPClient, untilCount: Int, maxWaitMs: Int = 2000) async -> [URLRequest] {
        var reqs = await stub.recordedRequests()
        var elapsed = 0
        while reqs.count < untilCount && elapsed < maxWaitMs {
            try? await Task.sleep(nanoseconds: 25_000_000)
            elapsed += 25
            reqs = await stub.recordedRequests()
        }
        return reqs
    }

    // MARK: - Tests

    @Test("同一パスの同時要求は1回だけフェッチし、両方の呼び出しに画像を配送する")
    func deduplicatesSamePath() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        async let a = batcher.thumbnail(for: item("/x.jpg"))
        async let b = batcher.thumbnail(for: item("/x.jpg"))
        let (ra, rb) = await (a, b)

        #expect(ra != nil)
        #expect(rb != nil)
        let reqs = await stub.recordedRequests()
        #expect(reqs.count == 1)
        #expect(paths(in: reqs[0]) == ["/x.jpg"])
    }

    @Test("25件超は1リクエストあたり最大 chunkSize 件に分割し全件取得する")
    func splitsIntoChunks() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub, chunkSize: 25)

        await withTaskGroup(of: UIImage?.self) { group in
            for i in 0..<30 {
                group.addTask { @MainActor in await batcher.thumbnail(for: self.item("/p\(i).jpg")) }
            }
            for await _ in group {}
        }

        let reqs = await stub.recordedRequests()
        let allPaths = reqs.flatMap { paths(in: $0) }
        #expect(Set(allPaths).count == 30)                    // 全件取得
        #expect(reqs.allSatisfy { paths(in: $0).count <= 25 }) // 各リクエスト ≤ 25
    }

    @Test("呼び出し元 Task をキャンセルしても fetch は完走する（キャンセル耐性）")
    func fetchSurvivesCancellation() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        // debounce を長めにして、flush 前にキャンセルできる窓を作る。
        let batcher = makeBatcher(stub, debounceNs: 60_000_000)

        let task = Task { @MainActor in await batcher.thumbnail(for: item("/c.jpg")) }
        try? await Task.sleep(nanoseconds: 5_000_000)   // enqueue は済んでいる
        task.cancel()
        let result = await task.value
        #expect(result == nil)                          // キャンセルされた待機者は nil

        // debounce 経過後に fetch が実行されることをポーリングで確認（pendingItems は残っている）。
        let reqs = await pollRequests(stub, untilCount: 1)
        #expect(reqs.count == 1)
        #expect(reqs.first.map { paths(in: $0) } == ["/c.jpg"])
    }

    @Test("HTTP エラー時は nil を返してハングしない")
    func httpErrorDeliversNil() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.status(500))
        let batcher = makeBatcher(stub)
        let result = await batcher.thumbnail(for: item("/e.jpg"))
        #expect(result == nil)
    }

    @Test("複数の異なるパスはまとめて取得し、各呼び出しに配送する")
    func deliversToMultipleWaiters() async {
        let stub = StubHTTPClient(responder: StubHTTPClient.thumbnailBatchSuccess(pngBase64: onePixelPNGBase64))
        let batcher = makeBatcher(stub)

        async let a = batcher.thumbnail(for: item("/a.jpg"))
        async let b = batcher.thumbnail(for: item("/b.jpg"))
        let (ra, rb) = await (a, b)

        #expect(ra != nil)
        #expect(rb != nil)
        let reqs = await stub.recordedRequests()
        #expect(reqs.count == 1)
        #expect(Set(paths(in: reqs[0])) == ["/a.jpg", "/b.jpg"])
    }
}
#endif
