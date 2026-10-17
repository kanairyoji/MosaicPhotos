import Foundation
import SwiftData

/// Dropbox の動画 1 本ぶんのキャッシュ（ADR-282）。
///
/// ⚠️ **写真の表（`CachedDropboxItem`）とは分けてある。** 写真の表は解析候補・顔・場所・
/// 撮影日の問い合わせ・軽い表（content_hash）・バックアップの突き合わせが全件を読む。
/// 同じ表に動画を入れると、その読み手全部に「動画を除く」を足して回ることになり、
/// 1 か所でも漏れると動画が解析や顔に紛れ込む（ADR-196 の形）。表を分ければ、
/// 動画を読むのは「動画を出す」と決めた画面だけになる。
@Model
final class CachedDropboxVideo {
    @Attribute(.unique) var path: String
    var name: String
    var contentHash: String?
    /// 撮影日時。訊くまでは一覧の `client_modified`（＝アップロード時刻）。
    var captureDate: Date?
    /// ファイルの大きさ（バイト）。
    var byteSize: Int64?
    /// 再生時間（秒）。`get_metadata` で訊いて入る。
    var duration: Double?
    var latitude: Double?
    var longitude: Double?
    /// `get_metadata` で長さ・撮影日時を訊いた日時（nil＝まだ）。
    /// 取れなかったことも記録する（何度訊いても無いものを毎回訊かない）。中身が変わったら nil へ戻す。
    var probedAt: Date?
    var cachedAt: Date

    init(path: String, name: String, contentHash: String?, captureDate: Date?,
         byteSize: Int64?, duration: Double?, latitude: Double?, longitude: Double?,
         cachedAt: Date = Date()) {
        self.path = path
        self.name = name
        self.contentHash = contentHash
        self.captureDate = captureDate
        self.byteSize = byteSize
        self.duration = duration
        self.latitude = latitude
        self.longitude = longitude
        self.cachedAt = cachedAt
    }
}
