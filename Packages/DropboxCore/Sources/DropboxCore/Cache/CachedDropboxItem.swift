import Foundation
import SwiftData

/// Cached metadata for a single Dropbox file entry.
///
/// `path` (Dropbox `path_lower`) is the primary key — paths are globally unique
/// within an account. `contentHash` enables cheap change detection: when the
/// hash returned by Dropbox differs from the cached value, the cached binaries
/// (thumbnail / full image) are invalidated and re-fetched on next access.
@Model
final class CachedDropboxItem {
    @Attribute(.unique) var path: String
    var name: String
    var contentHash: String?
    var captureDate: Date?
    /// 撮影地の緯度・経度（`media_info` から取得。未取得時は nil）。追加プロパティは軽量マイグレーション。
    var latitude: Double?
    var longitude: Double?
    /// **撮影日時を Dropbox に問い合わせた日時**（ADR-201）。nil＝まだ訊いていない。
    ///
    /// ⚠️ Dropbox は一覧系 API（`list_folder` / `continue` / `get_thumbnail_batch`）で
    /// **`media_info` を返さない**（2019-12-02 以降・公式 SDK の記述）。つまり一覧から取れる
    /// 日付は `client_modified`＝**アップロード時刻**で、撮影日時ではない。実際の撮影日時は
    /// `files/get_metadata` を 1 枚ずつ叩くしかない。
    ///
    /// 訊いた事実をここに残すのは、**無かったことも憶えておく**ため（CLAUDE.md 性能原則 3）。
    /// EXIF が無い写真は何度訊いても無いので、毎回往復すると 6.8 万枚ぶんの無駄になる。
    /// 中身が差し替わったら（contentHash が変わったら）`applyDelta` が nil へ戻す＝訊き直す。
    var captureDateProbedAt: Date?
    /// **EXIF の撮影日時だけ**（`get_metadata` の `media_info.time_taken`＝Dropbox が元写真の EXIF から
    /// 読んだ値）。アップロード時刻は**決して入れない**。
    ///
    /// ⚠️ `captureDate` は「EXIF が取れればそれ、取れなければアップロード時刻のまま」なので、
    /// 値を見ても**どちらなのか区別できない**。顔の撮影日（赤ちゃんの時期の決まり・ADR-61）に
    /// アップロード時刻を使うと、数年ずれた日付で判定してしまう。撮影日時が要る判断はこちらを使う。
    var exifCaptureDate: Date?
    /// `exifCaptureDate` を問い合わせた日時（nil＝まだ）。この列より前に問い合わせた行は
    /// どちらだったか分からないので、もう一度だけ問い合わせ直す（`captureDateProbedAt` とは別）。
    var exifProbedAt: Date?
    var cachedAt: Date

    init(
        path: String,
        name: String,
        contentHash: String? = nil,
        captureDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        captureDateProbedAt: Date? = nil,
        cachedAt: Date = Date()
    ) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        self.captureDate = captureDate
        self.latitude = latitude
        self.longitude = longitude
        self.captureDateProbedAt = captureDateProbedAt
        self.cachedAt = cachedAt
    }
}
