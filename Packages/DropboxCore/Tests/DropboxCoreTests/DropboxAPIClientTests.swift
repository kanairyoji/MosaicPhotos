import Foundation
import Testing
@testable import DropboxCore

private func okResponse(_ body: String) -> @Sendable (URLRequest) -> (Data, URLResponse) {
    { req in (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
}

@Suite("DropboxAPIClient")
@MainActor
struct DropboxAPIClientTests {

    @Test("rpc は Bearer 認証と JSON ヘッダ・ボディを付与する")
    func rpcAddsAuthAndJSON() async throws {
        let stub = StubHTTPClient(responder: okResponse("{}"))
        let client = DropboxAPIClient(httpClient: stub, tokenProvider: StubTokenProvider())
        let body = Data(#"{"a":1}"#.utf8)
        _ = try await client.rpc(url: "https://example.com/api", jsonBody: body)

        let reqs = await stub.recordedRequests()
        #expect(reqs.count == 1)
        #expect(reqs[0].httpMethod == "POST")
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == "Bearer stub-token")
        #expect(reqs[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(reqs[0].httpBody == body)
    }

    @Test("contentDownload は Bearer と Dropbox-API-Arg を付与し本体を返す")
    func contentDownloadAddsArgHeader() async throws {
        let stub = StubHTTPClient(responder: okResponse("binary-bytes"))
        let client = DropboxAPIClient(httpClient: stub, tokenProvider: StubTokenProvider())
        let data = try await client.contentDownload(url: "https://example.com/download", apiArg: #"{"path":"/a.jpg"}"#)

        #expect(data == Data("binary-bytes".utf8))
        let reqs = await stub.recordedRequests()
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == "Bearer stub-token")
        #expect(reqs[0].value(forHTTPHeaderField: "Dropbox-API-Arg") == #"{"path":"/a.jpg"}"#)
    }

    @Test("非200は APIError.http を投げる")
    func nonOKThrows() async {
        let stub = StubHTTPClient { req in
            (Data("conflict".utf8), HTTPURLResponse(url: req.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        }
        let client = DropboxAPIClient(httpClient: stub, tokenProvider: StubTokenProvider())
        await #expect(throws: DropboxAPIClient.APIError.self) {
            _ = try await client.rpc(url: "https://example.com/api", jsonBody: Data())
        }
    }
}
