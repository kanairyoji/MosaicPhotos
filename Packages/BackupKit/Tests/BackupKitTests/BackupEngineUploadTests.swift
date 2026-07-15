import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// HTTP 応答を記録・差し替えできるスタブ。`DropboxBackupUploader` のステータス分類と
/// リクエスト組み立て（ヘッダ・Dropbox-API-Arg のエスケープ）を検証する。
private actor StubHTTPClient: HTTPClient {
    enum Behavior {
        case status(Int, body: String)
        case throwError
    }
    let behavior: Behavior
    private(set) var lastRequest: URLRequest?

    init(_ behavior: Behavior) { self.behavior = behavior }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        switch behavior {
        case .throwError:
            throw URLError(.notConnectedToInternet)
        case let .status(code, body):
            let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), resp)
        }
    }

    func recorded() -> URLRequest? { lastRequest }
}

@Suite("DropboxBackupUploader")
struct DropboxBackupUploaderTests {

    private func makeUploader(_ behavior: StubHTTPClient.Behavior) -> (DropboxBackupUploader, StubHTTPClient) {
        let stub = StubHTTPClient(behavior)
        return (DropboxBackupUploader(httpClient: stub), stub)
    }

    /// "img" の content_hash（テスト内で共有）。
    private var imgHash: String { DropboxContentHash.hash(of: Data("img".utf8)) }

    @Test("HTTP 200＋hash 一致は .uploaded（検証済み）")
    func status200Verified() async {
        let hash = DropboxContentHash.hash(of: Data("img".utf8))
        let (uploader, _) = makeUploader(.status(200, body:
            #"{"content_hash":"\#(hash)","path_lower":"/a.jpg"}"#))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: hash)
        #expect(result == .uploaded(path: "/a.jpg", contentHash: hash))
    }

    @Test("HTTP 200 でも hash 不一致は .hashMismatch（絶対に済み扱いしない）")
    func status200HashMismatch() async {
        let (uploader, _) = makeUploader(.status(200, body:
            #"{"content_hash":"deadbeef","path_lower":"/a.jpg"}"#))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: imgHash)
        #expect(result == .hashMismatch(expected: imgHash, actual: "deadbeef"))
    }

    @Test("HTTP 200 で応答に content_hash が無い場合も .hashMismatch")
    func status200NoHash() async {
        let (uploader, _) = makeUploader(.status(200, body: "{}"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: imgHash)
        #expect(result == .hashMismatch(expected: imgHash, actual: nil))
    }

    @Test("HTTP 409 は .alreadyExists（既存ファイル）")
    func status409() async {
        let (uploader, _) = makeUploader(.status(409, body: "conflict"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: imgHash)
        #expect(result == .alreadyExists)
    }

    @Test("その他のステータスは .error(code, body)")
    func statusOther() async {
        let (uploader, _) = makeUploader(.status(500, body: "boom"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: imgHash)
        #expect(result == .error(500, "boom"))
    }

    @Test("通信例外は .networkError")
    func networkError() async {
        let (uploader, _) = makeUploader(.throwError)
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok",
                                           expectedHash: imgHash)
        if case .networkError = result { } else { Issue.record("expected .networkError, got \(result)") }
    }

    @Test("リクエストは POST・Bearer トークン・octet-stream で組み立てられる")
    func requestShape() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "my-token",
                                  expectedHash: imgHash)
        let req = await stub.recorded()
        #expect(req?.httpMethod == "POST")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer my-token")
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test("非ASCII パスは Dropbox-API-Arg で \\uXXXX エスケープされる（生の日本語を含めない）")
    func nonAsciiPathEscaped() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.upload(data: Data("img".utf8), to: "/写真.jpg", token: "tok",
                                  expectedHash: imgHash)
        let arg = await stub.recorded()?.value(forHTTPHeaderField: "Dropbox-API-Arg")
        #expect(arg?.contains("\\u") == true)
        #expect(arg?.contains("写") == false)
    }

    @Test("listFolder はファイルのみを path→hash で返す（フォルダは除外・not_found は空）")
    func listFolder() async {
        let body = #"""
        {"entries":[
          {".tag":"file","path_lower":"/backup/a.jpg","content_hash":"h1"},
          {".tag":"folder","path_lower":"/backup/.mosaic"},
          {".tag":"file","path_lower":"/backup/.mosaic/catalog.json","content_hash":"h2"}
        ],"cursor":"cur","has_more":false}
        """#
        let (uploader, _) = makeUploader(.status(200, body: body))
        let files = await uploader.listFolder(root: "/backup", token: "tok")
        #expect(files == ["/backup/a.jpg": "h1", "/backup/.mosaic/catalog.json": "h2"])
        // フォルダ未作成（409 not_found）は「ファイルゼロ」＝空辞書
        let (missing, _) = makeUploader(.status(409, body: #"{"error_summary":"path/not_found/"}"#))
        #expect(await missing.listFolder(root: "/none", token: "tok") == [:])
        // サーバエラーは nil（照合を中断＝記録を消さない）
        let (broken, _) = makeUploader(.status(500, body: "boom"))
        #expect(await broken.listFolder(root: "/backup", token: "tok") == nil)
    }

    @Test("getMetadata は content_hash と size を返す・404 は nil")
    func getMetadata() async {
        let (uploader, _) = makeUploader(.status(200, body:
            #"{"content_hash":"abc123","size":42}"#))
        let info = await uploader.getMetadata(path: "/a.jpg", token: "tok")
        #expect(info == RemoteFileInfo(contentHash: "abc123", size: 42))
        let (missing, _) = makeUploader(.status(409, body: "not_found"))
        #expect(await missing.getMetadata(path: "/gone.jpg", token: "tok") == nil)
    }

    @Test("uploadMetadata は 200 で entries 数を含む OK 要約を返す")
    func uploadMetadataOK() async {
        let (uploader, _) = makeUploader(.status(200, body: "{}"))
        let metadata = DropboxBackupMetadata(entries: [
            "/a.jpg": .init(people: ["Alice"]),
            "/b.jpg": .init(people: ["Bob"]),
        ])
        let summary = await uploader.uploadMetadata(metadata, to: "/Backup/.mosaic/metadata.json", token: "tok")
        #expect(summary.contains("OK"))
    }

    @Test("uploadMetadata は overwrite モードで送信する")
    func uploadMetadataOverwrite() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.uploadMetadata(DropboxBackupMetadata(), to: "/x/.mosaic/metadata.json", token: "tok")
        let arg = await stub.recorded()?.value(forHTTPHeaderField: "Dropbox-API-Arg")
        #expect(arg?.contains("overwrite") == true)
    }
}
