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

    /// **同じパスのまま中身が差し替わった回数**（ADR-258）。軽い表のディスク控えの鍵の一部。
    ///
    /// ⚠️ なぜ列が要るか: 控えの鍵は「行数」「未問い合わせ数」で大半の変化を捕まえられるが、
    /// **パスも件数も同じまま hash だけ変わる**（Dropbox 上で写真を上書き）のは数で捕まらない。
    /// ⚠️⚠️ 最初は `UserDefaults` に置いたが、**プロセスで 1 つしかない**ので
    /// 別のストアの更新がこちらの鍵を動かした（テストが並行で落ちて気づいた）。
    /// 鍵の材料は**その容器から導けるもの**でなければならない。
    /// optional 列の追加だけなので既存データは壊れない（ADR-186）。
    var indexContentVersion: Int?

    init(accountId: String, cursor: String? = nil, lastSyncedAt: Date? = nil,
         initialSyncCompletedAt: Date? = nil) {
        self.accountId = accountId
        self.cursor = cursor
        self.lastSyncedAt = lastSyncedAt
        self.initialSyncCompletedAt = initialSyncCompletedAt
    }
}
