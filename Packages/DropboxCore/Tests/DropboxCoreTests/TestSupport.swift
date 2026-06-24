import Foundation
@testable import DropboxCore

/// 固定トークンを返すテスト用プロバイダ（認証実体なし）。
@MainActor
final class StubTokenProvider: AccessTokenProvider {
    let token: String
    init(token: String = "stub-token") { self.token = token }
    func freshAccessToken() async throws -> String { token }
}

/// 固定時刻を返すテスト用 `DateProvider`。
struct FixedDateProvider: DateProvider {
    let now: Date
    init(_ now: Date) { self.now = now }
}

/// Keychain を使わないインメモリ `CredentialStore`（save/load/delete を検証可能）。
final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private(set) var stored: DropboxCredential?
    init(_ initial: DropboxCredential? = nil) { stored = initial }
    func save(_ credential: DropboxCredential) throws { stored = credential }
    func load() -> DropboxCredential? { stored }
    func delete() throws { stored = nil }
}

/// 条件が真になるまで（またはタイムアウトまで）ポーリングで待つ。
/// 並列 @MainActor テストでも安定するよう、固定 sleep ではなく条件駆動で待つ。
@MainActor
func waitUntil(timeoutMs: Int = 3000, _ condition: @MainActor () -> Bool) async {
    var elapsed = 0
    while !condition() && elapsed < timeoutMs {
        try? await Task.sleep(nanoseconds: 25_000_000)
        elapsed += 25
    }
}
