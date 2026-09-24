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

    /// ⚠️ **id を作らずに比べる**（ADR-119）。`id` は毎回 String を作るので、
    /// 全走査で使うと 1 タップで 12 万本の確保になる。接頭辞と中身を直接見る。
    public func hasID(_ candidate: String) -> Bool {
        switch self {
        case .local(let item):
            return candidate.hasPrefix("L-") && candidate.dropFirst(2) == item.id
        case .cloud(let item):
            return candidate.hasPrefix("C-") && candidate.dropFirst(2) == item.id
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

    /// ⚠️ **id を作らずにハッシュする**（常駐メモリの棚卸し）。一覧の指紋は全件に対して
    /// これを呼ぶので、`hasher.combine(id)` だと 1 回の指紋計算で 12 万本の String を
    /// 確保して捨てることになる（`hasID` と同じ理由・ADR-119 が名指しする形）。
    /// 種別を先に混ぜるので、`"L-"`/`"C-"` の接頭辞と同じだけ区別できる。
    public func hashIdentity(into hasher: inout Hasher) {
        switch self {
        case .local(let item):
            hasher.combine(0 as UInt8)
            hasher.combine(item.id)
        case .cloud(let item):
            hasher.combine(1 as UInt8)
            hasher.combine(item.id)
        }
    }

    /// ⚠️ ここも **id を作らない**。`lhs.id == rhs.id` は 1 回の比較で String を 2 本作る。
    public static func == (lhs: MergedPhotoItem, rhs: MergedPhotoItem) -> Bool {
        switch (lhs, rhs) {
        case (.local(let l), .local(let r)): return l.id == r.id
        case (.cloud(let l), .cloud(let r)): return l.id == r.id
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hashIdentity(into: &hasher)
    }
}

// LocalPhotoItem が @unchecked Sendable のため、MergedPhotoItem も同様にする。
extension MergedPhotoItem: @unchecked Sendable {}
#endif
