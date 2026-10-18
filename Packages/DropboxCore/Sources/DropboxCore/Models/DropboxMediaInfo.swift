import Foundation

/// Dropbox の `media_info`（撮影地・撮影日時・動画の長さ）のデコードモデル。
/// `list_folder`（include_media_info）と `get_metadata` の双方で共有する。
/// `media_info` が `pending` の場合は `metadata` が nil。
struct DropboxMediaInfo: Decodable {
    struct GpsCoordinates: Decodable, Equatable {
        let latitude: Double
        let longitude: Double
    }
    struct MediaMetadata: Decodable, Equatable {
        let location: GpsCoordinates?
        let time_taken: String?
        /// 動画の長さ（ミリ秒・`.tag` が `video` のときだけ入る）。
        let duration: Int64?

        /// 長さ（秒）。負や 0 は「分からない」と同じに扱う。
        var durationSeconds: TimeInterval? {
            guard let duration, duration > 0 else { return nil }
            return TimeInterval(duration) / 1000
        }
    }
    let metadata: MediaMetadata?
    /// `metadata` / `pending`。⚠️ `pending` は「まだ解析中」＝**後で訊けば取れる**ので、
    /// 「情報が無い」と同じに扱わない（ADR-282 のレビュー指摘）。
    let tag: String?

    enum CodingKeys: String, CodingKey {
        case metadata
        case tag = ".tag"
    }
}
