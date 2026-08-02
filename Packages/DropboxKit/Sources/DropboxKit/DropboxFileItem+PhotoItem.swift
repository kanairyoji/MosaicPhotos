#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit

extension DropboxFileItem: PhotoItem {
    /// Dropbox はクラウドソース（フィルタのソース絞り込み用）。
    public var isCloudSource: Bool { true }
    /// アプリ側お気に入りに対応（Dropbox に favorite は無いが cloudPath 単位でアプリが管理）。
    /// `isFavorite` は DropboxFileItem の stored プロパティ（DropboxPhotoStore が刻印）で満たす。
    public var supportsFavorite: Bool { true }
}
#endif
