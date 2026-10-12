import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// **複数アカウントの偽 Dropbox が本物と同じに振る舞うこと**。
///
/// 家族共有の通し（`FamilySharingScenarioTests`）はこの上に乗るので、ここが嘘をつくと
/// 通しは「本物では起きないこと」を確かめることになる。どれも「その振る舞いを外すと落ちる」形。
@Suite("偽 Dropbox（複数アカウント・共有フォルダ）")
struct FakeDropboxCloudTests {

    private func rpc(_ client: HTTPClient, _ endpoint: String,
                     _ json: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        let (data, response) = try await client.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private func upload(_ client: HTTPClient, _ path: String, _ data: Data) async throws -> Int {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        request.setValue(#"{"path":"\#(path)","mode":"add","autorename":false}"#,
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        let (_, response) = try await client.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    /// アプリの一覧の経路（`DropboxShareCopier.listFolder`）で読む。
    private func list(_ client: HTTPClient, _ path: String, recursive: Bool = true) async -> [String]? {
        await DropboxShareCopier(httpClient: client).listFolder(path: path, token: "t", recursive: recursive)?
            .map(\.pathLower).sorted()
    }

    private func family() async -> (FakeDropboxCloud, FakeDropboxAccount, FakeDropboxAccount) {
        let cloud = FakeDropboxCloud()
        let alice = await cloud.account("alice")
        let bob = await cloud.account("bob")
        await alice.upload(path: "/MosaicPhotos/dev/Share/Trip/a.jpg", data: Data("a".utf8))
        return (cloud, alice, bob)
    }

    @Test("アカウントは互いの名前空間を見られない")
    func accountsAreIsolated() async {
        let (_, alice, bob) = await family()
        #expect(await alice.visibleFiles() == ["/mosaicphotos/dev/share/trip/a.jpg"])
        #expect(await bob.visibleFiles().isEmpty, "共有していないのに他人のファイルが見える")
        #expect(await list(bob, "/MosaicPhotos/dev/Share") == nil, "他人のパスが自分の Dropbox にある")
    }

    @Test("共有フォルダは受ける人のルート直下にフォルダ名で現れ、中はその下のパスで見える")
    func sharedFolderAppearsAtTheRoot() async {
        let (cloud, _, bob) = await family()
        let mount = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        #expect(mount == "/Share")
        #expect(await list(bob, mount) == ["/share/trip", "/share/trip/a.jpg"])
        let root = await list(bob, "", recursive: false)
        #expect(root?.contains("/share") == true, "ルートの一覧に共有フォルダが無い: \(String(describing: root))")
    }

    @Test("同じ名前があれば、共有フォルダは「名前 (1)」で現れる（2 人から同じ名前でも衝突しない）")
    func mountNamesDoNotCollide() async {
        let (cloud, _, bob) = await family()
        let carol = await cloud.account("carol")
        await carol.upload(path: "/MosaicPhotos/dev/Share/Trip/c.jpg", data: Data("c".utf8))
        await bob.makeFolder("/Share")   // 受ける人に元から同名のフォルダがある
        let fromAlice = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        let fromCarol = await cloud.share("/MosaicPhotos/dev/Share", of: "carol", with: "bob")
        #expect(fromAlice == "/Share (1)")
        #expect(fromCarol == "/Share (2)")
        #expect(await list(bob, fromAlice) == ["/share (1)/trip", "/share (1)/trip/a.jpg"])
        #expect(await list(bob, fromCarol) == ["/share (2)/trip", "/share (2)/trip/c.jpg"])
    }

    @Test("閲覧のみの共有フォルダには書けない（no_write_permission）・編集なら書ける")
    func viewerCannotWrite() async throws {
        let (cloud, alice, bob) = await family()
        let mount = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        #expect(try await upload(bob, "\(mount)/Trip/b.jpg", Data("b".utf8)) == 409)
        let delete = try await rpc(bob, "files/delete_batch", #"{"entries":[{"path":"\#(mount)/Trip/a.jpg"}]}"#)
        #expect(delete.status == 409 && delete.body.contains("no_write_permission"))
        #expect(await alice.visibleFiles() == ["/mosaicphotos/dev/share/trip/a.jpg"], "閲覧者が持ち主のファイルを変えた")
        #expect(await bob.writesIntoShared.count == 2)

        let editorMount = await cloud.share("/MosaicPhotos/dev/Share/Trip", of: "alice", with: "bob",
                                            access: .editor)
        #expect(try await upload(bob, "\(editorMount)/b.jpg", Data("b".utf8)) == 200)
        #expect(await alice.visibleFiles().contains("/mosaicphotos/dev/share/trip/b.jpg"),
                "編集者の書き込みが持ち主に届かない（中身は 1 つのはず）")
    }

    @Test("持ち主のコピー・削除は、受ける人の差分（共有フォルダに張ったカーソル）に届く")
    func ownerChangesReachTheMembersDelta() async throws {
        let (cloud, alice, bob) = await family()
        let mount = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        let latest = try await rpc(bob, "files/list_folder/get_latest_cursor", #"{"path":"\#(mount)"}"#)
        struct Cursor: Decodable { let cursor: String }
        let cursor = try JSONDecoder().decode(Cursor.self, from: Data(latest.body.utf8)).cursor

        await alice.upload(path: "/MosaicPhotos/dev/Share/Trip/new.jpg", data: Data("n".utf8))
        await alice.remove("/MosaicPhotos/dev/Share/Trip/a.jpg")

        let delta = try await rpc(bob, "files/list_folder/continue", #"{"cursor":"\#(cursor)"}"#)
        #expect(delta.status == 200)
        #expect(delta.body.contains(#""path_lower":"/share/trip/new.jpg""#), "追加が届かない: \(delta.body)")
        #expect(delta.body.contains(#"".tag":"deleted","name":"a.jpg","path_lower":"/share/trip/a.jpg""#),
                "削除が届かない: \(delta.body)")
        #expect(!delta.body.contains("/~alice"), "全体のパスが漏れている（アカウントから見えるパスに直っていない）")
    }

    /// diagnostics-82: 家族フォルダが消えたあと、`continue` が 409 を返し続けた。
    @Test("共有を外されると一覧も差分カーソルも path/not_found")
    func unsharingRemovesTheFolder() async throws {
        let (cloud, _, bob) = await family()
        let mount = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        let latest = try await rpc(bob, "files/list_folder/get_latest_cursor", #"{"path":"\#(mount)"}"#)
        struct Cursor: Decodable { let cursor: String }
        let cursor = try JSONDecoder().decode(Cursor.self, from: Data(latest.body.utf8)).cursor

        await cloud.unshare(mount, from: "bob")
        #expect(await list(bob, mount) == nil, "外されたのに一覧できる")
        let delta = try await rpc(bob, "files/list_folder/continue", #"{"cursor":"\#(cursor)"}"#)
        #expect(delta.status == 409 && delta.body.contains("not_found"))
        #expect(await bob.visibleFiles().isEmpty)
    }

    @Test("共有フォルダから自分のフォルダへはコピーできる（中身は同じ）")
    func copyOutOfASharedFolder() async throws {
        let (cloud, alice, bob) = await family()
        let mount = await cloud.share("/MosaicPhotos/dev/Share", of: "alice", with: "bob")
        let copy = try await rpc(bob, "files/copy_batch_v2",
                                 #"{"entries":[{"from_path":"\#(mount)/Trip/a.jpg","to_path":"/Mine/a.jpg"}],"autorename":false}"#)
        #expect(copy.status == 200)
        #expect(copy.body.contains(#""path_lower":"/mine/a.jpg""#), "応答のパスが直っていない: \(copy.body)")
        #expect(await bob.contentHash(at: "/Mine/a.jpg") == (await alice.contentHash(at: "/MosaicPhotos/dev/Share/Trip/a.jpg")))
        #expect(await bob.writesIntoShared.isEmpty, "自分のフォルダへのコピーを共有フォルダへの書き込みと数えた")
    }

    @Test("アカウントごとに別の account_id")
    func accountIDsDiffer() async throws {
        let (_, alice, bob) = await family()
        let a = try await rpc(alice, "users/get_current_account", "null")
        let b = try await rpc(bob, "users/get_current_account", "null")
        #expect(a.body.contains("dbid:alice") && b.body.contains("dbid:bob"))
    }

    @Test("ルートに張る差分カーソルは作らない（模していないことを 400 で知らせる）")
    func rootDeltaIsNotModeled() async throws {
        let (_, _, bob) = await family()
        #expect(try await rpc(bob, "files/list_folder/get_latest_cursor", #"{"path":""}"#).status == 400)
    }
}
