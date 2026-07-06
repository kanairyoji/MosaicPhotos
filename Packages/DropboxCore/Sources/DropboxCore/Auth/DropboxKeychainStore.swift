import Foundation
import Security

public struct DropboxKeychainStore {
    private let service = "app.sampleapp.dropbox"
    private let iso8601 = ISO8601DateFormatter()

    public init() {}

    public func save(_ credential: DropboxCredential) throws {
        try write(.accessToken, value: credential.accessToken)
        try writeOptional(.refreshToken, value: credential.refreshToken)
        try writeOptional(.expiresAt, value: credential.expiresAt.map { iso8601.string(from: $0) })
        try writeOptional(.accountId, value: credential.accountId)
        try write(.connectedAt, value: iso8601.string(from: credential.connectedAt))
        try writeOptional(.lastRefreshedAt, value: credential.lastRefreshedAt.map { iso8601.string(from: $0) })
    }

    public func load() -> DropboxCredential? {
        guard let accessToken = read(.accessToken) else { return nil }
        let credential = DropboxCredential(
            accessToken: accessToken,
            refreshToken: read(.refreshToken),
            expiresAt: read(.expiresAt).flatMap { iso8601.date(from: $0) },
            accountId: read(.accountId),
            connectedAt: read(.connectedAt).flatMap { iso8601.date(from: $0) } ?? Date(),
            lastRefreshedAt: read(.lastRefreshedAt).flatMap { iso8601.date(from: $0) }
        )
        migrateAccessibilityIfNeeded(credential)
        return credential
    }

    /// 既存アイテムの accessibility 移行（WhenUnlocked → AfterFirstUnlock）。
    /// `write` は delete→add のため、一度保存し直せば新属性になる。読めた（＝アンロック中）
    /// タイミングで 1 回だけ実行する。
    private func migrateAccessibilityIfNeeded(_ credential: DropboxCredential) {
        let flag = "dropbox.keychainAccessibilityMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        try? save(credential)
        UserDefaults.standard.set(true, forKey: flag)
    }

    public func delete() throws {
        for key in ItemKey.allCases {
            try deleteItem(key)
        }
    }

    // MARK: - Private

    private enum ItemKey: String, CaseIterable {
        case accessToken, refreshToken, expiresAt, accountId, connectedAt, lastRefreshedAt
    }

    private func write(_ key: ItemKey, value: String) throws {
        let deleteQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecValueData: Data(value.utf8),
            // AfterFirstUnlock: 夜間のバックグラウンド処理（BGProcessingTask・ロック中）でも
            // Dropbox トークンを読めるようにする（WhenUnlocked だとロック中は読めず、
            // クラウド写真の索引・バックアップが夜間に全滅する）。再起動後の初回アンロック前のみ不可。
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw StoreError.writeFailed(status)
        }
    }

    private func writeOptional(_ key: ItemKey, value: String?) throws {
        if let value {
            try write(key, value: value)
        } else {
            try? deleteItem(key)
        }
    }

    private func read(_ key: ItemKey) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteItem(_ key: ItemKey) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.deleteFailed(status)
        }
    }

    public enum StoreError: Error {
        case writeFailed(OSStatus)
        case deleteFailed(OSStatus)
    }
}
