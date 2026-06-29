import Foundation

/// HTTP 通信の抽象。本番は `URLSessionHTTPClient`、テストはスタブ実装を注入することで、
/// ネットワークを介さずに同期エンジン・サムネイルバッチ・認証のロジックを検証できる。
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// 本番用の `URLSession` ベース実装。
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .dropboxDefault) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public extension URLSession {
    /// Dropbox 用の共有セッション。`content.dropboxapi.com` への並行ダウンロード
    /// （サムネイルの並行バッチ最大4本＋本体画像）を捌くため、host あたり接続数を引き上げる
    /// （既定の 6 だと並行サムネ取得が頭打ちになる）。longpoll/RPC は別ホストなので影響しない。
    static let dropboxDefault: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    /// longpoll 専用セッション。longpoll は 30〜50s 接続を保持し続けるため、共有セッションから
    /// 隔離して、保持し続ける接続が他の通信（サムネ/RPC/フル画像）のスケジューリングや
    /// タイムアウト管理に干渉しないようにする（longpoll は別ホスト＝notify だが、念のため分離）。
    static let dropboxLongpoll: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 120   // 接続を寝かせ続けてよいので長めに
        return URLSession(configuration: configuration)
    }()
}
