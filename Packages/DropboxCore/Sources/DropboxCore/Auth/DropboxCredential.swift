import Foundation

public struct DropboxCredential {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let accountId: String?
    public let connectedAt: Date
    public let lastRefreshedAt: Date?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        accountId: String?,
        connectedAt: Date,
        lastRefreshedAt: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
        self.connectedAt = connectedAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}
