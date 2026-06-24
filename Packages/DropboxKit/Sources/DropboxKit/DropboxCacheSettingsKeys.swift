import Foundation

/// Dropbox キャッシュ上限の永続設定キー。`DropboxSettingsView` で使用する。
enum DropboxCacheSettingsKeys {
    static let thumbnailLimitMB = "dropboxThumbLimitMB"
    static let fullImageLimitMB = "dropboxFullImageLimitMB"
    /// サムネイルの同時バッチ取得数（並列ダウンロード本数）。
    static let thumbnailConcurrency = "dropboxThumbConcurrency"
}
