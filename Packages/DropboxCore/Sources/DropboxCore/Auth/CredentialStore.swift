import Foundation

/// Dropbox 資格情報の永続化抽象。本番は `DropboxKeychainStore`（Keychain）、テストは
/// インメモリ実装を注入することで、Keychain entitlement なしに保存/復元/削除を検証できる。
public protocol CredentialStore {
    func save(_ credential: DropboxCredential) throws
    func load() -> DropboxCredential?
    func delete() throws
}

extension DropboxKeychainStore: CredentialStore {}
