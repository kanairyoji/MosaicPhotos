import Foundation
import Observation

/// Dropbox の各通信チャンネルの「今どれだけ動いているか」を集約するライブ計測。
///
/// 設計:
/// - すべてのチャンネル（サムネイル並列スロット / 同期 / フル画像DL / バックアップupload）が
///   このシングルトンへ状態を報告し、UI（`DropboxKit.DropboxActivityBar`）が `@Observable`
///   として購読する。`Diagnostics` / `LogChannel` と同じ「横断的なグローバル計測」の系列。
/// - 報告は MainActor 上の Int/enum 代入のみで非常に軽量。表示が OFF でも常時更新して構わない。
/// - 値の保持のみ。描画・スロットリングは持たない（UI 側の責務）。
@MainActor
@Observable
public final class DropboxActivityMonitor {
    public static let shared = DropboxActivityMonitor()

    // MARK: - Thumbnail batcher（並列スロット）

    /// サムネイルの同時実行スロット数（= バッチャの `maxConcurrentRequests`）。
    public private(set) var thumbnailSlotCapacity: Int = DropboxThumbnailSettings.defaultConcurrency
    /// 現在稼働中のスロット数（in-flight バッチ本数）。0…capacity。
    public private(set) var thumbnailActiveSlots: Int = 0
    /// バッチ待ちのサムネイル枚数（`pendingItems.count`）。
    public private(set) var thumbnailPending: Int = 0

    // MARK: - Sync（差分同期）

    public enum SyncActivity: Equatable, Sendable {
        case idle
        case initialSync
        case polling
        case fetchingDelta
        case error
    }
    public private(set) var sync: SyncActivity = .idle

    // MARK: - Full image download

    /// 進行中のフル画像ダウンロード本数。
    public private(set) var fullImageActive: Int = 0

    // MARK: - Backup upload

    /// バックアップのアップロードが進行中か（直列アップローダのため 0/1 相当）。
    public private(set) var backupActive: Bool = false

    private init() {}

    // MARK: - Reporting API（すべて MainActor・軽量）

    public func setThumbnailCapacity(_ n: Int) { thumbnailSlotCapacity = max(0, n) }
    public func setThumbnailActiveSlots(_ n: Int) {
        thumbnailActiveSlots = min(max(0, n), thumbnailSlotCapacity)
    }
    public func setThumbnailPending(_ n: Int) { thumbnailPending = max(0, n) }

    public func setSync(_ activity: SyncActivity) { sync = activity }

    public func beginFullImage() { fullImageActive += 1 }
    public func endFullImage() { fullImageActive = max(0, fullImageActive - 1) }

    public func setBackupActive(_ active: Bool) { backupActive = active }
}
