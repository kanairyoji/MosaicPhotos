import Foundation

/// ローカル写真サムネイルキャッシュの永続設定キー。
/// 読み手（`ThumbnailCache`）と書き手（`LocalPhotoSettingsView`）で共有する。
public enum CacheSettingsKeys {
    public static let memoryLimitMB = "cacheMemoryLimitMB"
    public static let diskLimitMB = "cacheDiskLimitMB"
}
