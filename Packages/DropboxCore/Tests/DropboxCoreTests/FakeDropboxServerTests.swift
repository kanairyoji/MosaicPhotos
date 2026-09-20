#if canImport(UIKit)
import DropboxTestSupport
import Foundation
import Testing
@testable import DropboxCore

/// **偽 Dropbox そのもののテスト**。
///
/// ⚠️ なぜ偽物にテストが要るか: このプロジェクトは**偽物が黙って嘘をつく**のを 2 回踏んだ。
///   - `get_metadata` が `size` を常に 1 で返し、オフロードの照合が**必ず失敗**していた
///     （＝オフロードの流れをどのテストも通っていなかった）
///   - `files/upload` が `mode=add` を無視して上書きし、同名衝突の経路が**存在しなかった**
/// どちらも「テストは緑だが、その経路を一度も通っていない」状態で、
/// **偽物を信じたぶんだけ本物が守られていなかった**。
/// 仕込みの意味（回数・対象・効果）は、ここで固定しておく。
@Suite("偽 Dropbox の仕込み（ルール表）")
struct FakeDropboxServerTests {

    private func request(_ endpoint: String, path: String, body: Data = Data()) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue(#"{"path":"\#(path)"}"#, forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = body
        return request
    }

    private func status(_ result: (Data, URLResponse)) -> Int {
        (result.1 as? HTTPURLResponse)?.statusCode ?? -1
    }

    // MARK: - 対象の絞り込み

    @Test("エンドポイントとパスの両方で絞れる")
    func faultsMatchEndpointAndPath() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", pathContains: ".mosaic",
                                  effect: .status(403)))

        #expect(status(try await server.data(for: request("files/upload", path: "/a/.mosaic/x.json"))) == 403)
        #expect(status(try await server.data(for: request("files/upload", path: "/a/photo.jpg"))) != 403,
                "パスで絞ったはずが、関係ないものまで落ちている")
        #expect(status(try await server.data(for: request("files/download", path: "/a/.mosaic/x.json"))) != 403,
                "エンドポイントで絞ったはずが、別の口まで落ちている")
    }

    /// ⚠️ **回数が要点**。恒久的な失敗しか作れないと「直ったら収束するか」を確かめられない。
    @Test("回数を指定すると、その回数だけ失敗して以後は通る")
    func faultsExpireAfterTheGivenTimes() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", times: 2, effect: .status(429)))

        #expect(status(try await server.data(for: request("files/upload", path: "/a.jpg"))) == 429)
        #expect(status(try await server.data(for: request("files/upload", path: "/a.jpg"))) == 429)
        #expect(status(try await server.data(for: request("files/upload", path: "/a.jpg"))) != 429,
                "指定した回数を超えても失敗し続けている（収束を確かめられない）")
    }

    /// ⚠️ **使われなかったルールを見つけられること**。テストが緑でも、仕込んだ失敗が
    /// 起きていなければ何も確かめていない——この罠を今日 2 回踏んだ。
    @Test("使われなかった仕込みは残って見える")
    func unusedFaultsAreVisible() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", times: 1, effect: .status(500)))
        await server.inject(.init(endpoint: "never/called", times: 1, effect: .status(500)))

        _ = try await server.data(for: request("files/upload", path: "/a.jpg"))

        let pending = await server.pendingFaults()
        #expect(pending.count == 1, "消費済みのルールが残っている、または未消費が見えない")
        #expect(pending.first?.endpoint == "never/called")
    }

    @Test("解除すると、以後は通る")
    func clearingFaultsRestoresNormalBehaviour() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", effect: .status(403)))
        #expect(status(try await server.data(for: request("files/upload", path: "/a.jpg"))) == 403)

        await server.clearFaults()

        #expect(status(try await server.data(for: request("files/upload", path: "/a.jpg"))) == 200)
        #expect(await server.pendingFaults().isEmpty)
    }

    // MARK: - 効果

    @Test("status は Retry-After ヘッダも返せる")
    func statusCanCarryRetryAfter() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", effect: .status(429, retryAfter: 7)))

        let result = try await server.data(for: request("files/upload", path: "/a.jpg"))

        let header = (result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
        #expect(header == "7", "アプリはこのヘッダを読む実装を持っているのに返していない")
    }

    /// 「HTTP 200 なのに中身が違う」——hash 照合が存在する理由そのもの。
    @Test("truncateBody は 200 のまま本文を途中で切る")
    func truncateBodyKeepsTheStatusButBreaksTheContent() async throws {
        let server = FakeDropboxServer()
        let data = Data("0123456789".utf8)
        await server.upload(path: "/a.bin", data: data)
        await server.inject(.init(endpoint: "files/download", pathContains: "a.bin",
                                  effect: .truncateBody))

        let result = try await server.data(for: request("files/download", path: "/a.bin"))

        #expect(status(result) == 200, "壊れた応答は 200 で返る（だから hash で見るしかない）")
        #expect(result.0.count < data.count, "本文が切れていない")
        #expect(DropboxContentHash.hash(of: result.0) != DropboxContentHash.hash(of: data))
    }

    @Test("networkError は接続そのものの失敗として投げる")
    func networkErrorThrows() async {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", effect: .networkError))

        await #expect(throws: URLError.self) {
            _ = try await server.data(for: self.request("files/upload", path: "/a.jpg"))
        }
    }

    /// ⚠️ `drop` はキャンセルされるまで戻らない。**キャンセルが効くか**を試すためのもの。
    @Test("drop は応答を返さず、キャンセルで抜ける")
    func dropNeverRespondsUntilCancelled() async {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", effect: .drop))

        let task = Task { try await server.data(for: self.request("files/upload", path: "/a.jpg")) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.result
        #expect((try? result.get()) == nil, "応答を返してしまっている")
    }

    @Test("delay は遅らせるだけで、応答そのものは通常どおり")
    func delayStillReturnsTheNormalResponse() async throws {
        let server = FakeDropboxServer()
        await server.inject(.init(endpoint: "files/upload", effect: .delay(milliseconds: 30)))

        let started = Date()
        let result = try await server.data(for: request("files/upload", path: "/a.jpg"))

        #expect(status(result) == 200, "遅らせただけなのに失敗している")
        #expect(Date().timeIntervalSince(started) >= 0.02, "遅延が効いていない")
    }

    // MARK: - 観測

    @Test("通信記録と回数が読める")
    func transcriptAndCountsAreReadable() async throws {
        let server = FakeDropboxServer()
        _ = try await server.data(for: request("files/upload", path: "/a.jpg",
                                               body: Data("hello".utf8)))
        _ = try await server.data(for: request("files/upload", path: "/b.jpg"))
        _ = try await server.data(for: request("files/get_metadata", path: "/a.jpg"))

        #expect(await server.callCounts()["files/upload"] == 2)
        #expect(await server.transcript().contains("files/upload /a.jpg → 200"))
        #expect(await server.trafficBytes().sent >= 5, "送信バイト数を数えていない")
    }
}
#endif
