import Foundation

/// Dropbox キャッシュの使用状況スナップショット（設定の表示用）。
public struct DropboxCacheUsage: Sendable, Equatable {
    public let itemCount: Int
    public let thumbnailBytes: Int
    public let fullImageBytes: Int

    public init(itemCount: Int, thumbnailBytes: Int, fullImageBytes: Int) {
        self.itemCount = itemCount
        self.thumbnailBytes = thumbnailBytes
        self.fullImageBytes = fullImageBytes
    }

    public var totalBytes: Int { thumbnailBytes + fullImageBytes }
}
