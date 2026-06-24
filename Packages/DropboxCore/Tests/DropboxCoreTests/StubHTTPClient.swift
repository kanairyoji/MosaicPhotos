import Foundation
@testable import DropboxCore

/// テスト用の `HTTPClient` スタブ。送られてきたリクエストを記録し、注入されたレスポンダで
/// 応答を返す。ネットワークを介さずに同期エンジン・バッチャの分岐を検証する。
actor StubHTTPClient: HTTPClient {
    private(set) var requests: [URLRequest] = []
    private let responder: @Sendable (URLRequest) -> (Data, URLResponse)

    init(responder: @escaping @Sendable (URLRequest) -> (Data, URLResponse)) {
        self.responder = responder
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return responder(request)
    }

    func recordedRequests() -> [URLRequest] { requests }

    // MARK: - Helpers

    /// `get_thumbnail_batch` のリクエストボディから entries 数を読み取り、その数だけ
    /// success エントリ（同じ 1×1 PNG base64）を返す HTTP 200 応答を組み立てる。
    static func thumbnailBatchSuccess(pngBase64: String) -> @Sendable (URLRequest) -> (Data, URLResponse) {
        return { request in
            struct Entry: Decodable { let path: String }
            struct Arg: Decodable { let entries: [Entry] }
            let count = (try? JSONDecoder().decode(Arg.self, from: request.httpBody ?? Data()))?.entries.count ?? 0
            let entriesJSON = (0..<count)
                .map { _ in "{\".tag\":\"success\",\"thumbnail\":\"\(pngBase64)\"}" }
                .joined(separator: ",")
            let json = "{\"entries\":[\(entriesJSON)]}"
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), resp)
        }
    }

    /// 常に指定ステータスの空レスポンスを返す（異常系テスト用）。
    static func status(_ code: Int) -> @Sendable (URLRequest) -> (Data, URLResponse) {
        return { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                       httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
    }
}

/// 1×1 透過 PNG の base64（`UIImage(data:)` でデコード可能）。
let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
