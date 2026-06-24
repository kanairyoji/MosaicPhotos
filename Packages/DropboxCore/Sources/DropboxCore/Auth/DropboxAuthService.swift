import AuthenticationServices
import CryptoKit
import Foundation
import Observation

// MARK: - Connection status

public enum DropboxConnectionStatus: Equatable {
    case notConnected
    case authenticating
    case connected
    case error(String)
}

// MARK: - Last error snapshot

public struct DropboxLastError {
    public let message: String
    public let date: Date
}

// MARK: - Service

@MainActor
@Observable
public final class DropboxAuthService {
    public private(set) var connectionStatus: DropboxConnectionStatus = .notConnected
    public private(set) var credential: DropboxCredential?
    public private(set) var lastError: DropboxLastError?

    @ObservationIgnored private let appKey: String
    @ObservationIgnored private let redirectURI: String
    @ObservationIgnored private let redirectURIScheme: String
    @ObservationIgnored private let keychainStore: CredentialStore
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private let dateProvider: DateProvider
    @ObservationIgnored private var authSession: ASWebAuthenticationSession?
    @ObservationIgnored private var contextProvider: ContextProvider?
    @ObservationIgnored private var refreshTask: Task<String, Error>?

    public init(
        appKey: String,
        redirectURI: String,
        httpClient: HTTPClient = URLSessionHTTPClient(),
        dateProvider: DateProvider = SystemDateProvider(),
        credentialStore: CredentialStore = DropboxKeychainStore()
    ) {
        self.appKey = appKey
        self.redirectURI = redirectURI
        self.redirectURIScheme = URL(string: redirectURI)?.scheme ?? ""
        self.httpClient = httpClient
        self.dateProvider = dateProvider
        self.keychainStore = credentialStore
        if let saved = keychainStore.load() {
            credential = saved
            connectionStatus = .connected
        }
    }

    // MARK: - Public API

    public func authenticate(presentationAnchor: ASPresentationAnchor) async {
        guard connectionStatus != .authenticating else { return }
        connectionStatus = .authenticating

        let codeVerifier = PKCEGenerator.makeVerifier(byteCount: DropboxInternalConstants.pkceVerifierByteCount)
        let codeChallenge = PKCEGenerator.challenge(for: codeVerifier)

        guard let authURL = buildAuthURL(codeChallenge: codeChallenge) else {
            fail("Failed to build the authorization URL.")
            return
        }

        do {
            let callbackURL = try await runWebSession(authURL: authURL, anchor: presentationAnchor)
            guard let code = extractCode(from: callbackURL) else {
                throw AuthError.noAuthCode
            }
            let newCredential = try await exchangeToken(code: code, codeVerifier: codeVerifier)
            try keychainStore.save(newCredential)
            credential = newCredential
            connectionStatus = .connected
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            connectionStatus = .notConnected
        } catch {
            fail(error.localizedDescription)
        }

        authSession = nil
        contextProvider = nil
    }

    public func cancelAuthentication() {
        authSession?.cancel()
        authSession = nil
        contextProvider = nil
        connectionStatus = .notConnected
    }

    public func setDirectToken(_ accessToken: String) async {
        guard connectionStatus != .authenticating else { return }
        connectionStatus = .authenticating
        do {
            let accountId = try await validateToken(accessToken)
            let newCredential = DropboxCredential(
                accessToken: accessToken,
                refreshToken: nil,
                expiresAt: nil,
                accountId: accountId,
                connectedAt: Date(),
                lastRefreshedAt: nil
            )
            try keychainStore.save(newCredential)
            credential = newCredential
            connectionStatus = .connected
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Token refresh

    public func freshAccessToken() async throws -> String {
        guard let cred = credential else {
            throw TokenError.notConnected
        }
        if let expiresAt = cred.expiresAt, expiresAt > dateProvider.now.addingTimeInterval(DropboxInternalConstants.tokenExpiryBufferSeconds) {
            return cred.accessToken
        }
        // No refresh token (e.g., direct token entry) — use as-is
        guard let refreshToken = cred.refreshToken else {
            return cred.accessToken
        }
        // Deduplicate concurrent refresh requests
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task { [weak self] () throws -> String in
            guard let self else { throw TokenError.notConnected }
            return try await self.performRefresh(refreshToken: refreshToken, existing: cred)
        }
        refreshTask = task
        do {
            let token = try await task.value
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefresh(refreshToken: String, existing: DropboxCredential) async throws -> String {
        var request = URLRequest(url: URL(string: DropboxInternalConstants.oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": appKey,
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        .joined(separator: "&")
        .data(using: .utf8)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw TokenError.refreshFailed(body)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let newCred = DropboxCredential(
            accessToken: decoded.access_token,
            refreshToken: existing.refreshToken,
            expiresAt: decoded.expires_in.map { dateProvider.now.addingTimeInterval(TimeInterval($0)) },
            accountId: existing.accountId,
            connectedAt: existing.connectedAt,
            lastRefreshedAt: dateProvider.now
        )
        try keychainStore.save(newCred)
        credential = newCred
        return newCred.accessToken
    }

    public func disconnect() {
        authSession?.cancel()
        authSession = nil
        contextProvider = nil
        try? keychainStore.delete()
        credential = nil
        lastError = nil
        connectionStatus = .notConnected
    }

    #if DEBUG
    /// テスト専用：OAuth フローを経ずに資格情報を直接注入する。
    /// 同一ファイル内のため `private(set)` の `credential` を設定できる。
    func setCredentialForTesting(_ credential: DropboxCredential) {
        self.credential = credential
        self.connectionStatus = .connected
    }
    #endif

    // MARK: - URL building

    private func buildAuthURL(codeChallenge: String) -> URL? {
        var components = URLComponents(string: DropboxInternalConstants.authPageURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "token_access_type", value: "offline"),
            // ⚠️ files.content.write を含めること。
            // 抜けると Dropbox が "missing_scope" を返しアップロードが全滅する（過去に発生）。
            // スコープを変更した場合は Dropbox Developer Portal の Permissions タブでも
            // 同じスコープを有効化し、ユーザーに再接続（再認証）を促す必要がある。
            URLQueryItem(name: "scope", value: "account_info.read files.metadata.read files.content.read files.content.write"),
        ]
        return components?.url
    }

    private func extractCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    // MARK: - Web session

    private func runWebSession(authURL: URL, anchor: ASPresentationAnchor) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let provider = ContextProvider(anchor: anchor)
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: redirectURIScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.unknownCallback)
                }
            }
            session.presentationContextProvider = provider
            session.prefersEphemeralWebBrowserSession = true
            contextProvider = provider
            authSession = session
            session.start()
        }
    }

    // MARK: - Token exchange

    private func exchangeToken(code: String, codeVerifier: String) async throws -> DropboxCredential {
        var request = URLRequest(url: URL(string: DropboxInternalConstants.oauthTokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": codeVerifier,
            "client_id": appKey,
            "redirect_uri": redirectURI,
        ]
        .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
        .joined(separator: "&")
        .data(using: .utf8)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AuthError.tokenExchangeFailed(body)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return DropboxCredential(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token,
            expiresAt: decoded.expires_in.map { dateProvider.now.addingTimeInterval(TimeInterval($0)) },
            accountId: decoded.account_id,
            connectedAt: Date(),
            lastRefreshedAt: nil
        )
    }

    // MARK: - Token validation

    private func validateToken(_ accessToken: String) async throws -> String? {
        var request = URLRequest(url: URL(string: DropboxInternalConstants.currentAccountURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "null".data(using: .utf8)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ValidationError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            let info = try? JSONDecoder().decode(AccountInfo.self, from: data)
            return info?.account_id
        case 401:
            throw ValidationError.invalidToken
        default:
            throw ValidationError.apiError(http.statusCode)
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        connectionStatus = .error(message)
        lastError = DropboxLastError(message: message, date: Date())
    }

    // MARK: - Nested types

    private struct RefreshResponse: Decodable {
        let access_token: String
        let expires_in: Int?
    }

    private enum TokenError: LocalizedError {
        case notConnected
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to Dropbox. Please reconnect from the Settings tab."
            case .refreshFailed(let msg): return "Failed to refresh token: \(msg)"
            }
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let account_id: String?
    }

    private enum AuthError: LocalizedError {
        case noAuthCode
        case unknownCallback
        case tokenExchangeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAuthCode: return "Failed to obtain authorization code."
            case .unknownCallback: return "Failed to handle callback."
            case .tokenExchangeFailed(let msg): return "Token exchange error: \(msg)"
            }
        }
    }

    private struct AccountInfo: Decodable {
        let account_id: String
    }

    private enum ValidationError: LocalizedError {
        case invalidToken
        case invalidResponse
        case apiError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Token is invalid or expired."
            case .invalidResponse: return "Invalid response from server."
            case .apiError(let code): return "API error: HTTP \(code)"
            }
        }
    }

    @MainActor
    private final class ContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        private let anchor: ASPresentationAnchor
        init(anchor: ASPresentationAnchor) { self.anchor = anchor }
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }
    }
}
