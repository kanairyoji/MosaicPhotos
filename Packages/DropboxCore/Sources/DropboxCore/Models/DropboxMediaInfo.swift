import Foundation

/// Dropbox の `media_info`（撮影地・撮影日時）のデコードモデル。
/// `list_folder`（include_media_info）と `get_metadata` の双方で共有する。
/// `media_info` が `pending` の場合は `metadata` が nil。
struct DropboxMediaInfo: Decodable {
    struct GpsCoordinates: Decodable {
        let latitude: Double
        let longitude: Double
    }
    struct MediaMetadata: Decodable {
        let location: GpsCoordinates?
        let time_taken: String?
    }
    let metadata: MediaMetadata?
}
