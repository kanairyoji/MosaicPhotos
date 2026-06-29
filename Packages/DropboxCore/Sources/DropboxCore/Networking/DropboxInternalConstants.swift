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

    // MARK: - Thumbnail batch

    static let thumbnailBatchChunkSize = 25
    /// バッチ（get_thumbnail_batch）リクエストの同時実行数。直列だと表示枚数増加時に
    /// ネットワーク往復が積み上がって遅いため、複数バッチを並行させて取得を高速化する。
    static let maxConcurrentThumbnailRequests = 4
    static let thumbnailBatchDebounceNs: UInt64 = 30_000_000   // 30 ms
    static let thumbnailFormat = "jpeg"
    static let thumbnailAPISize = "w128h128"

    // MARK: - Sync / list_folder

    static let listFolderPageLimit = 2000
    static let parallelFolderScanBatchSize = 8
    static let longpollTimeoutSeconds = 30
    /// URLRequest タイムアウト。longpoll の待機時間に十分な余裕を持たせる。
    static let longpollURLRequestTimeout: TimeInterval = 120
    static let retryDelayNs: UInt64 = 30_000_000_000           // 30 s

    // MARK: - Cache defaults (DropboxCacheStore)

    static let defaultThumbnailByteLimit = 50 * 1_024 * 1_024    // 50 MB
    static let defaultFullImageByteLimit = 200 * 1_024 * 1_024   // 200 MB
    /// サムネのメモリ層（NSCache）の上限。実デコードサイズでコスト計上する（128px≈64KB）。
    /// 保持を厚くしてディスク再デコード（実機で ~129ms/枚）を減らす。
    static let thumbnailMemoryCostLimit = 80 * 1_024 * 1_024     // 80 MB（≈1250枚）
    static let thumbnailMemoryCountLimit = 1600
    /// 圧迫時にサムネメモリ層を絞る下限（既定 16MB だと残数が少なく再デコードが多発するため大きめ）。
    static let thumbnailMemoryPressureFloor = 40 * 1_024 * 1_024 // 40 MB（≈620枚を保持）
    /// サムネのデコード（ディスク読込＋強制デコード／ネット応答のデコード）の同時実行上限。
    /// 要求ごとに無制限の Task.detached を生むと協調スレッドプールが飽和し 1 枚が桁違いに遅くなる。
    static let thumbnailDecodeConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)

    // MARK: - JPEG compression quality

    static let thumbnailJPEGQuality: CGFloat = 0.85
    static let fullImageJPEGQuality: CGFloat = 0.9

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
