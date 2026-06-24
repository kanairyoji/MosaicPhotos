import Foundation

/// 設定の「Dropbox — Debug」セクションで表示する内部チューニング定数（読み取り専用）。
/// 実体は internal な `DropboxInternalConstants`。consumer（DropboxKit）から参照できるよう public へ転送する。
public enum DropboxDebugConstants {
    public static var tokenExpiryBufferSeconds: Int { Int(DropboxInternalConstants.tokenExpiryBufferSeconds) }
    public static var pkceVerifierByteCount: Int { DropboxInternalConstants.pkceVerifierByteCount }
    public static var thumbnailBatchChunkSize: Int { DropboxInternalConstants.thumbnailBatchChunkSize }
    public static var thumbnailBatchDebounceMs: Int { Int(DropboxInternalConstants.thumbnailBatchDebounceNs / 1_000_000) }
    public static var thumbnailAPISize: String { DropboxInternalConstants.thumbnailAPISize }
    public static var listFolderPageLimit: Int { DropboxInternalConstants.listFolderPageLimit }
    public static var parallelFolderScanBatchSize: Int { DropboxInternalConstants.parallelFolderScanBatchSize }
    public static var longpollTimeoutSeconds: Int { DropboxInternalConstants.longpollTimeoutSeconds }
    public static var retryDelaySeconds: Int { Int(DropboxInternalConstants.retryDelayNs / 1_000_000_000) }
    public static var defaultThumbnailLimitMB: Int { DropboxInternalConstants.defaultThumbnailByteLimit / (1_024 * 1_024) }
    public static var defaultFullImageLimitMB: Int { DropboxInternalConstants.defaultFullImageByteLimit / (1_024 * 1_024) }
    public static var thumbnailJPEGQuality: Double { Double(DropboxInternalConstants.thumbnailJPEGQuality) }
    public static var fullImageJPEGQuality: Double { Double(DropboxInternalConstants.fullImageJPEGQuality) }
}
