import DropboxCore
import DropboxTestSupport
import Foundation
import Testing

/// **偽 Dropbox の監査そのもののテスト**（ADR-278 追補 7）。
///
/// ⚠️ 監査（守るべき中身・消えてよい場所・往復ごとの口）は「落ちないと価値が無い」仕掛けで、
/// 壊れていても不変条件のテストは**緑のまま**になる。わざと違反する操作を投げ、
/// 名指しで数えることを確かめる（CLAUDE.md「検査を足したら、その検査が効いていることも検査する」）。
@Suite("偽 Dropbox の監査")
struct FakeDropboxAuditTests {

    private func rpc(_ server: FakeDropboxServer, _ endpoint: String, _ body: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        let (_, response) = try await server.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private func delete(_ server: FakeDropboxServer, _ paths: [String]) async throws {
        let entries = paths.map { #"{"path":"\#($0)"}"# }.joined(separator: ",")
        _ = try await rpc(server, "files/delete_batch", #"{"entries":[\#(entries)]}"#)
    }

    private func move(_ server: FakeDropboxServer, _ from: String, _ to: String) async throws {
        _ = try await rpc(server, "files/move_v2", #"{"from_path":"\#(from)","to_path":"\#(to)"}"#)
    }

    // MARK: - 守るべき中身

    @Test("守るべき中身をフォルダから消すと数え、同じ中身が残る削除は数えない")
    func protectedDeleteIsCounted() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s/a.jpg", hash: "h1")
        await server.seed("/s/b.jpg", hash: "h1")      // 同じ中身の 2 枚目
        await server.seed("/s/c.jpg", hash: "h2")
        await server.seed("/s/d.jpg", hash: "h9")      // 守らない中身
        await server.setProtectedContents(["/S": ["h1", "h2"]])   // 大文字でも同じフォルダ

        try await delete(server, ["/s/a.jpg"])
        #expect(await server.removedProtectedCopies == 0, "同じ中身が残る削除を数えた")
        try await delete(server, ["/s/d.jpg"])
        #expect(await server.removedProtectedCopies == 0, "守らない中身を数えた")
        try await delete(server, ["/s/b.jpg"])
        #expect(await server.removedProtectedCopies == 1)
        #expect(await server.removedProtectedCopyPaths == ["/s/b.jpg"])
    }

    @Test("フォルダごとの削除は配下を 1 枚ずつ数える")
    func protectedFolderDeleteIsCounted() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s", hash: "", isFolder: true)
        await server.seed("/s/a.jpg", hash: "h1")
        await server.seed("/s/c.jpg", hash: "h2")
        await server.setProtectedContents(["/s": ["h1", "h2"]])
        try await delete(server, ["/s"])
        #expect(await server.removedProtectedCopies == 2)
    }

    @Test("フォルダの外へ移すと数え、同じフォルダの中での改名は数えない")
    func protectedMoveIsCounted() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s/a.jpg", hash: "h1")
        await server.setProtectedContents(["/s": ["h1"]])
        try await move(server, "/s/a.jpg", "/s/renamed.jpg")
        #expect(await server.removedProtectedCopies == 0, "同じフォルダの中の改名を数えた")
        try await move(server, "/s/renamed.jpg", "/removed/renamed.jpg")
        #expect(await server.removedProtectedCopies == 1)
    }

    // MARK: - 消えてよい場所

    @Test("消えてよい場所にしか残らない削除は、厳しい数にだけ入る")
    func disposableSurvivorIsNotDurable() async throws {
        let server = FakeDropboxServer()
        await server.seed("/root/dev1/share/s/a.jpg", hash: "h1")
        await server.seed("/root/dev2/share/s/a.jpg", hash: "h1")   // 他の端末の共有コピー
        await server.seed("/root/dev1/share/s/b.jpg", hash: "h2")
        await server.seed("/root/dev1/backup/b.jpg", hash: "h2")    // 消えない場所の実物
        await server.setDisposableLocation { $0.contains("/share/") }

        try await delete(server, ["/root/dev1/share/s/a.jpg"])
        #expect(await server.deletedLastCopies == 0, "前提: 緩い数はアカウントのどこかに残れば数えない")
        #expect(await server.deletedLastDurableCopies == 1, "他の端末の共有コピーを、残っている数に入れた")
        #expect(await server.deletedLastDurableCopyPaths == ["/root/dev1/share/s/a.jpg"])

        try await delete(server, ["/root/dev1/share/s/b.jpg"])
        #expect(await server.deletedLastDurableCopies == 1, "消えない場所に実物が在るのに数えた")
    }

    @Test("消えてよい場所を設定しなければ、厳しい数は数えない（既存のテストの意味を変えない）")
    func durableCountIsOptIn() async throws {
        let server = FakeDropboxServer()
        await server.seed("/a/x.jpg", hash: "h1")
        try await delete(server, ["/a/x.jpg"])
        #expect(await server.deletedLastCopies == 1)
        #expect(await server.deletedLastDurableCopies == 0)
    }

    // MARK: - 往復ごとの口

    @Test("往復ごとの口は応答の前に呼ばれ、そこで書いたものは次の往復から見える")
    func requestHookRunsBetweenRequests() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s/a.jpg", hash: "h1")
        let calls = Counter()
        await server.setRequestHook { endpoint in
            await calls.add(endpoint)
            if await calls.count == 1 { await server.seed("/s/late.jpg", hash: "h2") }
        }
        try await delete(server, ["/s/a.jpg"])
        #expect(await calls.endpoints == ["files/delete_batch"])
        #expect(await server.entry(at: "/s/late.jpg") != nil, "口で置いたファイルが無い")
        await server.setRequestHook(nil)
        try await delete(server, ["/s/late.jpg"])
        #expect(await calls.count == 1, "外した口が呼ばれた")
    }

    private actor Counter {
        var endpoints: [String] = []
        var count: Int { endpoints.count }
        func add(_ endpoint: String) { endpoints.append(endpoint) }
    }
}

extension FakeDropboxAuditTests {
    @Test("作り直せる場所の削除は、どちらの最後の 1 枚にも数えない")
    func rebuildableIsExempt() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s/.mosaic-share/shard-ab.json", hash: "j1")
        await server.seed("/s/a.jpg", hash: "h1")
        await server.setDisposableLocation { _ in false }
        await server.setRebuildableLocation { $0.contains("/.mosaic-share/") }
        try await delete(server, ["/s/.mosaic-share/shard-ab.json"])
        #expect(await server.deletedLastCopies == 0)
        #expect(await server.deletedLastDurableCopies == 0)
        try await delete(server, ["/s/a.jpg"])
        #expect(await server.deletedLastCopies == 1, "作り直せる場所の外まで免除した")
        #expect(await server.deletedLastDurableCopies == 1)
    }
}

extension FakeDropboxAuditTests {
    @Test("守るべきファイルは、同じ中身がフォルダに残らない限り数える（中身で守れないメンバー用）")
    func protectedPathIsCounted() async throws {
        let server = FakeDropboxServer()
        await server.seed("/s/mine.jpg", hash: "h1")
        await server.seed("/s/other.jpg", hash: "h2")
        await server.setProtectedPaths(["/S/Mine.jpg"])
        try await delete(server, ["/s/other.jpg"])
        #expect(await server.removedProtectedCopies == 0, "守っていないファイルを数えた")
        try await move(server, "/s/mine.jpg", "/elsewhere/mine.jpg")
        #expect(await server.removedProtectedCopies == 1)
    }
}
