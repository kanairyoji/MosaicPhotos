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

    @Test("HTTP 200 は .uploaded")
    func status200() async {
        let (uploader, _) = makeUploader(.status(200, body: "{}"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok")
        #expect(result == .uploaded)
    }

    @Test("HTTP 409 は .alreadyExists（既存ファイル）")
    func status409() async {
        let (uploader, _) = makeUploader(.status(409, body: "conflict"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok")
        #expect(result == .alreadyExists)
    }

    @Test("その他のステータスは .error(code, body)")
    func statusOther() async {
        let (uploader, _) = makeUploader(.status(500, body: "boom"))
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok")
        #expect(result == .error(500, "boom"))
    }

    @Test("通信例外は .networkError")
    func networkError() async {
        let (uploader, _) = makeUploader(.throwError)
        let result = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "tok")
        if case .networkError = result { } else { Issue.record("expected .networkError, got \(result)") }
    }

    @Test("リクエストは POST・Bearer トークン・octet-stream で組み立てられる")
    func requestShape() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.upload(data: Data("img".utf8), to: "/a.jpg", token: "my-token")
        let req = await stub.recorded()
        #expect(req?.httpMethod == "POST")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer my-token")
        #expect(req?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
    }

    @Test("非ASCII パスは Dropbox-API-Arg で \\uXXXX エスケープされる（生の日本語を含めない）")
    func nonAsciiPathEscaped() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.upload(data: Data("img".utf8), to: "/写真.jpg", token: "tok")
        let arg = await stub.recorded()?.value(forHTTPHeaderField: "Dropbox-API-Arg")
        #expect(arg?.contains("\\u") == true)
        #expect(arg?.contains("写") == false)
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
        #expect(summary.contains("2 total entries"))
    }

    @Test("uploadMetadata は overwrite モードで送信する")
    func uploadMetadataOverwrite() async {
        let (uploader, stub) = makeUploader(.status(200, body: "{}"))
        _ = await uploader.uploadMetadata(DropboxBackupMetadata(), to: "/x/.mosaic/metadata.json", token: "tok")
        let arg = await stub.recorded()?.value(forHTTPHeaderField: "Dropbox-API-Arg")
        #expect(arg?.contains("overwrite") == true)
    }
}
