#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit

extension DropboxFileItem: PhotoItem {
    /// Dropbox はクラウドソース（フィルタのソース絞り込み用）。
    public var isCloudSource: Bool { true }
}
#endif
