import Foundation

/// アクセストークン供給の抽象。`DropboxAuthService` が適合する。
///
/// Batcher / SyncEngine / BackupEngine は具象の認証サービスではなくこのプロトコルに
/// 依存することで、認証実体（Keychain・OAuth）なしにユニットテストできる。
/// `DropboxAuthService.freshAccessToken()` が `@MainActor` のため、本プロトコルも `@MainActor`。
@MainActor
public protocol AccessTokenProvider: AnyObject {
    /// 有効なアクセストークンを返す（期限切れなら自動リフレッシュ）。
    func freshAccessToken() async throws -> String
}

extension DropboxAuthService: AccessTokenProvider {}
