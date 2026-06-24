import Foundation

/// MosaicPhotos アプリ固有の Dropbox OAuth 設定値。
/// DropboxCore には持たせず、呼び出し側 (このファイル) で管理する。
///｀
/// `appKey` は git に上げない別ファイル `DropboxSecrets.swift`（`.gitignore` 対象）に置く。
/// 初回は `DropboxSecrets.swift.example` をコピーして自分の Dropbox app key を記入する。
enum DropboxConfig {
    static let appKey = DropboxSecrets.appKey
    static let redirectURI = "MosaicPhotos://oauth/dropbox"
}
