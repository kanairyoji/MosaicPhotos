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

    /// お気に入りはローカル写真のみ（Dropbox にはお気に入りの概念がない）。
    public var isFavorite: Bool {
        switch self {
        case .local(let item): return item.isFavorite
        case .cloud:           return false
        }
    }

    /// お気に入りの付け外しはローカル写真のみ対応。
    public var supportsFavorite: Bool {
        switch self {
        case .local(let item): return item.supportsFavorite
        case .cloud:           return false
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
