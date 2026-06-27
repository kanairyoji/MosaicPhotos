import Foundation

/// バイト数を KB/MB 表記へ整形する共通ヘルパ（各設定画面のキャッシュ使用量表示で共用）。
/// 以前は LocalPhotoKit / DropboxKit に同一実装が重複していたためここへ集約した。
public func formatBytes(_ bytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(bytes))
}
