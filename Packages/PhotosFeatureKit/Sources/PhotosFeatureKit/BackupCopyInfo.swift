import Foundation

/// バックアップ副本 1 件の「表示に要る最小の記録」。
///
/// ⚠️ 表示側が要るのは 2 つだけ——**どの端末写真の副本か**（二重表示を隠す）と、
/// **元の撮影日**（Dropbox の日付がアップロード時刻に落ちている場合の上書き）。
/// この型は `PhotosFeatureKit` が所有する（BackupKit へ依存しないため）。アプリの
/// Composition Root が台帳の記録をここへ写して渡す。
public struct BackupCopyInfo: Sendable, Equatable {
    public let localIdentifier: String?
    public let captureDate: Date?
    /// **同じ中身が別の場所にもあるコピー**なら、代わりに残すコピーのパス（小文字・ADR-276）。
    /// 同じ Dropbox の他の端末の共有コピー（`ShareCopyDuplicates`）がこれになる。
    /// nil＝重複ではない（隠す理由にならない＝安全側）。
    public let duplicateOf: String?

    public init(localIdentifier: String?, captureDate: Date?, duplicateOf: String? = nil) {
        self.localIdentifier = localIdentifier
        self.captureDate = captureDate
        self.duplicateOf = duplicateOf
    }
}
