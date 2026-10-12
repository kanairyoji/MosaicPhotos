import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// **偽 Dropbox が本物と同じに振る舞うこと**（2026-10-12 の強化・ADR-275）。
///
/// ⚠️ 偽物が本物と違うと、その違いの上に乗った経路は**どのテストも通らない**
/// （`get_metadata` の size が常に 1 でオフロードの照合が必ず落ちていた、`mode=add` を
/// 無視して同名衝突が存在しなかった——`FakeDropboxServer` 冒頭）。ここで固定するのは、
/// 強化の前は偽物に**無かった**本物の振る舞い。どれも「古い偽物に戻すと落ちる」形にしてある。
///
/// macOS で走る（DropboxCore 側の偽物のテストは UIKit 依存でシミュレータ専用のため）。
@Suite("偽 Dropbox の忠実度")
struct FakeDropboxFidelityTests {

    // MARK: - 要求の組み立て（アプリの経路と同じ形）

    private func rpc(_ server: FakeDropboxServer, _ endpoint: String,
                     _ json: String) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        let (data, response) = try await server.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
    }

    private func upload(_ server: FakeDropboxServer, path: String, data: Data,
                        clientModified: String? = nil) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!)
        request.httpMethod = "POST"
        let modified = clientModified.map { #","client_modified":"\#($0)""# } ?? ""
        request.setValue(#"{"path":"\#(path)","mode":"add","autorename":false\#(modified)}"#,
                         forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data
        let (body, response) = try await server.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, String(decoding: body, as: UTF8.self))
    }

    private struct ListEntry: Decodable {
        let tag: String
        let path_lower: String
        let rev: String?
        let client_modified: String?
        let server_modified: String?
        let name: String?
        enum CodingKeys: String, CodingKey {
            case tag = ".tag", path_lower, rev, client_modified, server_modified, name
        }
    }
    private struct ListPage: Decodable { let entries: [ListEntry]; let cursor: String }

    private func list(_ server: FakeDropboxServer, _ path: String,
                      recursive: Bool = false) async throws -> [ListEntry] {
        let result = try await rpc(server, "files/list_folder",
                                   #"{"path":"\#(path)","recursive":\#(recursive)}"#)
        #expect(result.status == 200, "一覧が取れない: \(result.body)")
        return try JSONDecoder().decode(ListPage.self, from: Data(result.body.utf8)).entries
    }

    /// 差分カーソルを取って、`body` のあとに何が変わったかを返す。
    private func changes(_ server: FakeDropboxServer, root: String,
                         during body: () async throws -> Void) async throws -> [ListEntry] {
        let latest = try await rpc(server, "files/list_folder/get_latest_cursor", #"{"path":"\#(root)"}"#)
        struct Cursor: Decodable { let cursor: String }
        let cursor = try JSONDecoder().decode(Cursor.self, from: Data(latest.body.utf8)).cursor
        try await body()
        let page = try await rpc(server, "files/list_folder/continue", #"{"cursor":"\#(cursor)"}"#)
        return try JSONDecoder().decode(ListPage.self, from: Data(page.body.utf8)).entries
    }

    // MARK: - 版（rev）

    @Test("書き直すと rev が変わる（中身が違えば必ず）")
    func revChangesOnRewrite() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/a/x.json", data: Data("v1".utf8))
        let first = await server.entry(at: "/a/x.json")?.rev
        await server.upload(path: "/a/x.json", data: Data("v2".utf8))
        let second = await server.entry(at: "/a/x.json")?.rev
        #expect(first != nil && first != second, "書き直しても rev が同じ（rev の差分で取り直す経路が死ぬ）")
    }

    /// ⚠️ 本物は同じ中身の upload で**新しい版を作らない**。偽物が毎回版を作ると、
    /// 「毎回同じ JSON を上げ直している」無駄が、受信側の差分（取り直し）として見えてしまう。
    @Test("同じ中身の upload は新しい版を作らず、差分にも載らない")
    func identicalUploadIsNotANewRevision() async throws {
        let server = FakeDropboxServer()
        let data = Data("same".utf8)
        _ = try await upload(server, path: "/a/x.json", data: data)
        let rev = await server.entry(at: "/a/x.json")?.rev
        let delta = try await changes(server, root: "/a") {
            let again = try await upload(server, path: "/a/x.json", data: data)
            #expect(again.status == 200, "同じ中身の add を衝突扱いした: \(again.body)")
        }
        #expect(await server.entry(at: "/a/x.json")?.rev == rev)
        #expect(delta.isEmpty, "変わっていないのに差分に載った: \(delta.map(\.path_lower))")
    }

    // MARK: - 日付

    @Test("client_modified は upload の引数がそのまま一覧に出る")
    func clientModifiedRoundTrips() async throws {
        let server = FakeDropboxServer()
        let sent = try await upload(server, path: "/a/p.jpg", data: Data("p".utf8),
                                    clientModified: "2019-05-04T03:02:01Z")
        #expect(sent.status == 200)
        let entry = try await list(server, "/a").first { $0.path_lower == "/a/p.jpg" }
        #expect(entry?.client_modified == "2019-05-04T03:02:01Z",
                "撮影日として送った日付が一覧に出ない（同期側の撮影日が今日になる）")
        #expect(entry?.server_modified != nil)
    }

    /// 本物は秒精度の UTC しか受け付けない（`DropboxBackupUploader.uploadAPIArg` の注記）。
    /// 形式を崩す変更は、この偽物の上で**写真が 1 枚も上がらない**として出る。
    @Test("client_modified の小数秒・時差つきは 400")
    func clientModifiedFormatIsStrict() async throws {
        let server = FakeDropboxServer()
        for bad in ["2019-05-04T03:02:01.123Z", "2019-05-04T12:02:01+09:00", "2019-05-04"] {
            let result = try await upload(server, path: "/a/\(bad.count).jpg", data: Data(bad.utf8),
                                          clientModified: bad)
            #expect(result.status == 400, "\(bad) を受け付けた（本物は 400）")
        }
        #expect(await server.filePaths().isEmpty)
    }

    @Test("アプリの uploader が送る client_modified は本物の形式を通る")
    func appUploaderSendsAcceptedFormat() async {
        let server = FakeDropboxServer()
        let data = Data("photo".utf8)
        let taken = Date(timeIntervalSince1970: 1_500_000_000.75)   // 小数秒を持つ撮影日
        let result = await DropboxBackupUploader(httpClient: server).upload(
            data: data, to: "/a/p.jpg", token: "t", expectedHash: DropboxContentHash.hash(of: data),
            clientModified: taken)
        guard case .uploaded = result else {
            Issue.record("アプリの形式が本物に弾かれる: \(result)")
            return
        }
        let stored = await server.entry(at: "/a/p.jpg")?.clientModified
        #expect(stored == Date(timeIntervalSince1970: 1_500_000_000), "秒に丸めた撮影日が残っていない")
    }

    /// ⚠️ 共有コピーの日付が「反映した時刻」に落ちる（実フィードバック・`SharedCaptureDates`）。
    /// 偽物がコピー元の日付を引き継ぐと、その対策（撮影日を別に配る）が要らないように見える。
    @Test("copy_batch のコピーは、コピーした時刻が client_modified になる")
    func copiesGetTheCopyTimeAsClientModified() async throws {
        let server = FakeDropboxServer()
        _ = try await upload(server, path: "/b/p.jpg", data: Data("p".utf8),
                             clientModified: "2015-01-01T00:00:00Z")
        await server.advanceClock(by: 86_400)
        let copy = try await rpc(server, "files/copy_batch_v2",
                                 #"{"entries":[{"from_path":"/b/p.jpg","to_path":"/s/Trip/P.jpg"}],"autorename":false}"#)
        #expect(copy.status == 200)
        let entry = await server.entry(at: "/s/trip/p.jpg")
        #expect(entry != nil, "コピーされていない")
        #expect(entry?.clientModified == (await server.now()), "コピーの日付がコピー元の撮影日のまま")
        #expect(entry?.displayName == "P.jpg", "コピー先の名前の大文字小文字が失われた")
        #expect(entry?.size == 1, "コピー先のサイズがコピー元と違う")
    }

    // MARK: - 差分に載ること

    /// ⚠️ 以前は upload だけが差分に載り、コピー・削除・移動は**受信側に一度も届かなかった**
    /// （共有を受ける側の差分同期が、偽物の上では「家族が何もしていない」に見えていた）。
    @Test("コピー・削除・移動は差分に載る")
    func relocationsAppearInTheDelta() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/b/a.jpg", data: Data("a".utf8))
        await server.upload(path: "/s/old.jpg", data: Data("o".utf8))
        await server.upload(path: "/s/move-me.jpg", data: Data("m".utf8))

        let delta = try await changes(server, root: "/s") {
            _ = try await rpc(server, "files/copy_batch_v2",
                              #"{"entries":[{"from_path":"/b/a.jpg","to_path":"/s/a.jpg"}],"autorename":false}"#)
            _ = try await rpc(server, "files/delete_batch", #"{"entries":[{"path":"/s/old.jpg"}]}"#)
            _ = try await rpc(server, "files/move_v2",
                              #"{"from_path":"/s/move-me.jpg","to_path":"/s/moved.jpg"}"#)
        }
        let byPath = Dictionary(delta.map { ($0.path_lower, $0.tag) }, uniquingKeysWith: { $1 })
        #expect(byPath["/s/a.jpg"] == "file", "コピーが差分に無い: \(byPath)")
        #expect(byPath["/s/old.jpg"] == "deleted", "削除が差分に無い: \(byPath)")
        #expect(byPath["/s/move-me.jpg"] == "deleted", "移動元が差分に無い: \(byPath)")
        #expect(byPath["/s/moved.jpg"] == "file", "移動先が差分に無い: \(byPath)")
        #expect(await server.body(at: "/s/moved.jpg") == Data("m".utf8), "移動で中身が失われた")
    }

    @Test("フォルダを消すと、配下のファイルも消えたとして差分に載る")
    func folderDeletionReportsChildren() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/s/Trip/a.jpg", data: Data("a".utf8))
        let delta = try await changes(server, root: "/s") {
            _ = try await rpc(server, "files/delete_batch", #"{"entries":[{"path":"/s/trip"}]}"#)
        }
        #expect(delta.contains { $0.path_lower == "/s/trip/a.jpg" && $0.tag == "deleted" },
                "配下の削除が届かない（受信側にファイルが残り続ける）: \(delta.map(\.path_lower))")
    }

    // MARK: - フォルダ

    @Test("コピー先の中間フォルダは自動で作られ、一覧できる")
    func copyCreatesParents() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/b/a.jpg", data: Data("a".utf8))
        _ = try await rpc(server, "files/copy_batch_v2",
                          #"{"entries":[{"from_path":"/b/a.jpg","to_path":"/s/x/y/a.jpg"}],"autorename":false}"#)
        let listed = try await list(server, "/s/x/y")
        #expect(listed.map(\.path_lower) == ["/s/x/y/a.jpg"])
    }

    @Test("フォルダは folder の形（rev・content_hash を持たない）で返る")
    func folderMetadataShape() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/s/Trip/a.jpg", data: Data("a".utf8))
        let folder = try await list(server, "/s").first { $0.path_lower == "/s/trip" }
        #expect(folder?.tag == "folder")
        #expect(folder?.rev == nil, "フォルダに rev を付けている（本物には無い）")
        let meta = try await rpc(server, "files/get_metadata", #"{"path":"/s/trip"}"#)
        #expect(meta.body.contains(#"".tag":"folder""#), "get_metadata のフォルダの形が違う: \(meta.body)")
    }

    @Test("ファイルのパスを一覧すると path/not_folder")
    func listingAFileIsNotFolder() async throws {
        let server = FakeDropboxServer()
        await server.upload(path: "/a/p.jpg", data: Data("p".utf8))
        let result = try await rpc(server, "files/list_folder", #"{"path":"/a/p.jpg"}"#)
        #expect(result.status == 409)
        #expect(result.body.contains("not_folder"), "本物の理由と違う: \(result.body)")
    }

    // MARK: - 上限・競合

    @Test("copy_batch / delete_batch は 1,000 件を超えると 400")
    func batchesAreLimited() async throws {
        let server = FakeDropboxServer()
        let limit = FakeDropboxServer.maxBatchEntries
        let copies = (0...limit).map { #"{"from_path":"/b/\#($0).jpg","to_path":"/s/\#($0).jpg"}"# }
        let copy = try await rpc(server, "files/copy_batch_v2",
                                 #"{"entries":[\#(copies.joined(separator: ","))],"autorename":false}"#)
        #expect(copy.status == 400, "1,001 件のコピーを受け付けた（本物は 400）")
        let deletes = (0...limit).map { #"{"path":"/s/\#($0).jpg"}"# }
        let delete = try await rpc(server, "files/delete_batch",
                                   #"{"entries":[\#(deletes.joined(separator: ","))]}"#)
        #expect(delete.status == 400, "1,001 件の削除を受け付けた（本物は 400）")

        let atLimit = (0..<limit).map { #"{"path":"/s/\#($0).jpg"}"# }
        let ok = try await rpc(server, "files/delete_batch", #"{"entries":[\#(atLimit.joined(separator: ","))]}"#)
        #expect(ok.status == 200, "ちょうど 1,000 件で弾いた")
    }

    /// diagnostics-74: 背景転送の最中にメタデータを書くと `too_many_write_operations` で全滅した。
    @Test("同時書き込みが上限を超えると 429 too_many_write_operations")
    func concurrentWritesConflict() async throws {
        let server = FakeDropboxServer()
        await server.setResponseDelay(milliseconds: 50)
        await server.setMaxConcurrentWrites(1)
        let statuses = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<4 {
                group.addTask {
                    try await self.upload(server, path: "/a/\(index).jpg", data: Data("\(index)".utf8)).status
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses.filter { $0 == 200 }.count >= 1)
        #expect(statuses.filter { $0 == 429 }.count >= 1, "同時に 4 本書いても競合しない: \(statuses)")
        #expect(await server.transcript().contains("429"))

        // 読み取りは競合しない（本物の書き込みロックは名前空間の書き込みだけ）。
        await server.setMaxConcurrentWrites(0)
        await server.setResponseDelay(milliseconds: 0)
    }

    // MARK: - 撮影情報

    @Test("media_info は get_metadata で include_media_info のときだけ返り、一覧には出ない")
    func mediaInfoOnlyFromGetMetadata() async throws {
        let server = FakeDropboxServer()
        await server.seed("/c/p.jpg", hash: "h",
                          mediaInfo: .init(timeTaken: Date(timeIntervalSince1970: 1_600_000_000),
                                           latitude: 35.0, longitude: 139.0))
        let with = try await rpc(server, "files/get_metadata",
                                 #"{"path":"/c/p.jpg","include_media_info":true}"#)
        #expect(with.body.contains("time_taken"), "撮影日が返らない: \(with.body)")
        #expect(with.body.contains("latitude"))
        let without = try await rpc(server, "files/get_metadata", #"{"path":"/c/p.jpg"}"#)
        #expect(!without.body.contains("media_info"))
        let listed = try await rpc(server, "files/list_folder", #"{"path":"/c"}"#)
        #expect(!listed.body.contains("media_info"), "一覧が撮影情報を返している（本物は 2019 年以降返さない）")
    }
}
