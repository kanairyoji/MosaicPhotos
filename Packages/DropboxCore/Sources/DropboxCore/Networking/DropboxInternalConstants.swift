import Foundation

/// サムネイル並行取得の設定レンジ（UI と batcher が共有する公開定数）。
/// 過大な同時数は Dropbox の 429（レート制限）や接続枯渇を招くため常識的な範囲に制限する。
public enum DropboxThumbnailSettings {
    public static let minConcurrency = 1
    public static let maxConcurrency = 8
    public static let defaultConcurrency = DropboxInternalConstants.maxConcurrentThumbnailRequests

    /// 設定値を許容範囲にクランプする。
    public static func clampConcurrency(_ value: Int) -> Int {
        min(maxConcurrency, max(minConcurrency, value))
    }
}

/// DropboxCore モジュール内で共有する内部定数。
/// アプリ固有の値（appKey・redirectURI 等）はここに置かない。
/// 呼び出し側が `DropboxAuthService.init` に渡す。
enum DropboxInternalConstants {

    // MARK: - API base URLs

    static let authPageURL = "https://www.dropbox.com/oauth2/authorize"
    static let oauthTokenURL = "https://api.dropboxapi.com/oauth2/token"
    static let currentAccountURL = "https://api.dropboxapi.com/2/users/get_current_account"
    static let getMetadataURL = "https://api.dropboxapi.com/2/files/get_metadata"
    static let listFolderURL = "https://api.dropboxapi.com/2/files/list_folder"
    static let listFolderContinueURL = "https://api.dropboxapi.com/2/files/list_folder/continue"
    static let listFolderLatestCursorURL = "https://api.dropboxapi.com/2/files/list_folder/get_latest_cursor"
    static let listFolderLongpollURL = "https://notify.dropboxapi.com/2/files/list_folder/longpoll"
    static let getThumbnailBatchURL = "https://content.dropboxapi.com/2/files/get_thumbnail_batch"
    static let downloadFileURL = "https://content.dropboxapi.com/2/files/download"

    // MARK: - Token management

    /// アクセストークンの残有効時間がこの秒数以下になったらリフレッシュする。
    static let tokenExpiryBufferSeconds: TimeInterval = 300

    /// PKCE コードベリファイアの生成に使うランダムバイト数。
    static let pkceVerifierByteCount = 96

    // MARK: - Thumbnail API params（バッチ並行・容量などのチューニング値は +Tuning.swift）

    static let thumbnailFormat = "jpeg"
    static let thumbnailAPISize = "w128h128"

    // MARK: - Sync / list_folder

    static let listFolderPageLimit = 2000
    static let parallelFolderScanBatchSize = 8
    static let longpollTimeoutSeconds = 30
    /// URLRequest タイムアウト。longpoll の待機時間に十分な余裕を持たせる。
    static let longpollURLRequestTimeout: TimeInterval = 120
    static let retryDelayNs: UInt64 = 30_000_000_000           // 30 s
    /// longpoll が「変更なし」を返した後、次の longpoll までの最小待ち。
    /// 本番の longpoll はサーバ側で最大 `longpollTimeoutSeconds` ブロックするので実害は無いが、
    /// もし longpoll が即座に返る場合（テストのスタブや異常）に pollLoop がビジーループ化して
    /// CPU を食い潰す（CI で main actor 飢餓→ハング）のを防ぐ協調的な下限。
    static let pollNoChangeMinDelayNs: UInt64 = 1_000_000_000   // 1 s

    // MARK: - Log truncation lengths

    static let cursorLogPrefixLong = 24
    static let cursorLogPrefixShort = 20

    // MARK: - Backup metadata

    /// バックアップフォルダ内のメタデータファイルの相対パス。
    /// フォルダパスに連結して使用する（例: "/MosaicPhotos" + suffix）。
    static let backupMetadataSuffix = "/.mosaic/metadata.json"

    // MARK: - Upload

    static let uploadFileURL = "https://content.dropboxapi.com/2/files/upload"
}
