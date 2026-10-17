#if canImport(UIKit)
import DropboxCore
import Foundation
import PhotoSourceKit

extension DropboxFileItem: PhotoItem {
    /// Dropbox はクラウドソース（フィルタのソース絞り込み用）。
    public var isCloudSource: Bool { true }
    /// アプリ側お気に入りに対応（Dropbox に favorite は無いが cloudPath 単位でアプリが管理）。
    /// `isFavorite` は DropboxFileItem の stored プロパティ（DropboxPhotoStore が刻印）で満たす。
    public var supportsFavorite: Bool { true }
    /// Dropbox 上の実パス（どのフォルダ由来かを画面で特定できるようにする）。
    public var sourceLocation: PhotoSourceLocation {
        PhotoSourceLocation(kind: .cloud, identifier: path)
    }
    /// 動画か（ADR-282）。一覧の解析で拡張子から決まり、`video` の有無に表れる。
    public var mediaKind: PhotoMediaKind { isVideo ? .video : .photo }
    /// 動画の長さ（まだ訊いていなければ nil）。
    public var videoDuration: TimeInterval? { video?.duration }
}
#endif
