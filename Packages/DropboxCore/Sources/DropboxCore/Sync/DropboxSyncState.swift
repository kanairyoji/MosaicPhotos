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
    /// **初回スキャンを最後までやり切った**時刻。nil＝未完了（中断された可能性がある）。
    ///
    /// ⚠️ カーソルはスキャン中にも書かれる（ページごとに書かないと、途中で落ちたときに
    /// 何も残らない）。そのため「カーソルがある＝初回同期済み」ではない。この区別が無いと、
    /// スキャン途中で終了したとき次回起動が **poll へ直行し、未走査フォルダの既存写真が
    /// 永久に取得されない**（レビュー指摘）。起動時の分岐はこの印で行う。
    var initialSyncCompletedAt: Date?

    init(accountId: String, cursor: String? = nil, lastSyncedAt: Date? = nil,
         initialSyncCompletedAt: Date? = nil) {
        self.accountId = accountId
        self.cursor = cursor
        self.lastSyncedAt = lastSyncedAt
        self.initialSyncCompletedAt = initialSyncCompletedAt
    }
}
