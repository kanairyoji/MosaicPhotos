import Foundation

/// `DropboxAuthService` のトークンリフレッシュ・直接トークン投入・トークン検証レイヤー。
/// OAuth 認可フロー（`DropboxAuthService.swift`）から切り離し、保存済み資格情報の更新と
/// アクセストークンの有効性確保をここに集約する。
extension DropboxAuthService {

    // MARK: - Direct token

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
}

// MARK: - Nested response / error types (token flow)

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
