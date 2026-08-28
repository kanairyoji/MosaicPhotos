#if canImport(UIKit)
import CoreLocation
import DropboxKit
import Foundation
import LocalPhotoKit
import PhotoSourceKit

// MARK: - Merged photo item

/// ローカル写真と Dropbox 写真を統合して扱う PhotoItem。
/// どちらのソースの写真かを保持し、サムネイル・本体取得を適切なストアへ委譲する。
public enum MergedPhotoItem: PhotoItem {
    case local(LocalPhotoItem)
    case cloud(DropboxFileItem)

    // ID 衝突を避けるためにプレフィックスを付与する。
    public var id: String {
        switch self {
        case .local(let item): return "L-\(item.id)"
        case .cloud(let item): return "C-\(item.id)"
        }
    }

    public var captureDate: Date? {
        switch self {
        case .local(let item): return item.captureDate
        case .cloud(let item): return item.captureDate
        }
    }

    public var coordinate: CLLocationCoordinate2D? {
        switch self {
        case .local(let item): return item.coordinate
        case .cloud(let item): return item.coordinate
        }
    }

    /// ソース種別（フィルタの「端末のみ／クラウドのみ」絞り込み用）。
    public var isCloudSource: Bool {
        switch self {
        case .local: return false
        case .cloud: return true
        }
    }

    /// 実体の所在は**中身へ委譲**する（"L-"/"C-" を付けた合成 id ではなく、
    /// 端末の localIdentifier / Dropbox の実パスをそのまま出す）。
    public var sourceLocation: PhotoSourceLocation {
        switch self {
        case .local(let item): return item.sourceLocation
        case .cloud(let item): return item.sourceLocation
        }
    }

    /// お気に入り。ローカルは PHAsset、クラウドは**アプリ側で管理**する（ADR-67）。
    /// ⚠️ 以前は「Dropbox にお気に入りの概念がない」として cloud を常に false にしていたが、
    /// ADR-67 で `DropboxPhotoStore` がアプリ側お気に入り（cloudFavoritePaths）を持つように
    /// なった。ここを更新し忘れていたため、統合ビュー（All Photos）だけクラウド写真の
    /// ハートが出ず、付け外しもできなかった。
    public var isFavorite: Bool {
        switch self {
        case .local(let item): return item.isFavorite
        case .cloud(let item): return item.isFavorite
        }
    }

    /// お気に入りの付け外しはローカル・クラウドとも対応（クラウドはアプリ側で永続）。
    public var supportsFavorite: Bool {
        switch self {
        case .local(let item): return item.supportsFavorite
        case .cloud(let item): return item.supportsFavorite
        }
    }

    public static func == (lhs: MergedPhotoItem, rhs: MergedPhotoItem) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// LocalPhotoItem が @unchecked Sendable のため、MergedPhotoItem も同様にする。
extension MergedPhotoItem: @unchecked Sendable {}
#endif
