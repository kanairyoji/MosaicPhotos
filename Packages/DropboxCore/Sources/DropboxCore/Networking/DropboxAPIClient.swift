import Foundation
import MosaicSupport

/// Dropbox の RPC / content ダウンロードについて、リクエスト構築・Bearer 認証ヘッダ付与・
/// ステータス検証を集約する薄いクライアント。`HTTPClient` と `AccessTokenProvider` を注入
/// してテスト可能にする。各所に散在していた URLRequest 組み立ての重複を 1 箇所へ寄せる。
///
/// 注意: longpoll（認証不要・専用タイムアウト）など特殊なリクエストは対象外で、
/// 呼び出し側が `HTTPClient` を直接使う。
@MainActor
final class DropboxAPIClient {
    private let httpClient: HTTPClient
    private let tokenProvider: AccessTokenProvider

    init(httpClient: HTTPClient, tokenProvider: AccessTokenProvider) {
        self.httpClient = httpClient
        self.tokenProvider = tokenProvider
    }

    enum APIError: LocalizedError {
        case http(status: Int, body: String)
        var errorDescription: String? {
            switch self {
            case let .http(status, body):
                return "HTTP \(status): \(body.prefix(200))"
            }
        }
    }

    /// RPC エンドポイント: JSON ボディを Bearer 認証付きで POST し、200 を検証して生データを返す。
    func rpc(url: String, jsonBody: Data) async throws -> Data {
        let token = try await tokenProvider.freshAccessToken()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonBody
        return try await send(req)
    }

    /// 認証不要の RPC（list_folder/longpoll 用）。専用タイムアウトを設定できる。
    func rpcNoAuth(url: String, jsonBody: Data, timeout: TimeInterval? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = jsonBody
        if let timeout { req.timeoutInterval = timeout }
        return try await send(req)
    }

    /// content ダウンロード: `Dropbox-API-Arg` ヘッダ付きで Bearer 認証 POST し、本体バイナリを返す。
    func contentDownload(url: String, apiArg: String) async throws -> Data {
        let token = try await tokenProvider.freshAccessToken()
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(apiArg, forHTTPHeaderField: "Dropbox-API-Arg")
        req.httpBody = Data()
        return try await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        // 計測: エンドポイント別のネットワーク往復時間とバイト数。Dropbox 体感速度の最重要指標。
        let t0 = PerfTrace.nowNs()
        let (data, response) = try await httpClient.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        PerfTrace.logSpan("net." + (request.url?.lastPathComponent ?? "?"),
                          ms: PerfTrace.msSince(t0),
                          detail: "\(data.count / 1024)KB status=\(status)")
        guard status == 200 else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
