import Foundation

/// バックアップ副本 1 件ぶんの「表示に要る最小の記録」。
///
/// ⚠️ 表示側（`MergedPhotoStore`）が要るのは 2 つだけ——**どの端末写真の副本か**（二重表示を
/// 隠すため）と、**元の撮影日**（Dropbox の日付がアップロード時刻に落ちている場合の上書き）。
/// 全カラムを持ち回らない（起動時に全記録を materialize しない・メモリの山を作らない）。
public struct BackupCopyRecord: Sendable, Equatable {
    /// 元の端末写真（`PHAsset.localIdentifier`）。旧形式・取り込み由来では nil。
    public let localIdentifier: String?
    /// 元写真の撮影日（`PHAsset.creationDate`）。
    public let captureDate: Date?

    public init(localIdentifier: String?, captureDate: Date?) {
        self.localIdentifier = localIdentifier
        self.captureDate = captureDate
    }
}
