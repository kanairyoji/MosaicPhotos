import Foundation
import SwiftData

/// Per-account synchronization state used for cursor-based delta sync against
/// Dropbox's `list_folder` / `list_folder/continue` endpoints.
///
/// `accountId` doubles as the key used to detect account switches: when the
/// connected account changes, the cache for the previous account should be
/// cleared via `DropboxCacheStore.clearAll(accountId:)`.
@Model
final class DropboxSyncState {
    @Attribute(.unique) var accountId: String
    var cursor: String?
    var lastSyncedAt: Date?

    init(accountId: String, cursor: String? = nil, lastSyncedAt: Date? = nil) {
        self.accountId = accountId
        self.cursor = cursor
        self.lastSyncedAt = lastSyncedAt
    }
}
