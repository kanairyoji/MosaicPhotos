#if canImport(UIKit)
import CoreLocation
import UIKit

/// アイテム単位の画像・メタ情報ローディング。`PhotoStore` が精緻化するため、
/// `Store: PhotoStore` の制約を持つ既存コードはそのまま全メソッドを利用できる。
///
/// コレクション/状態/ライフサイクル（`items` / `state` / `start` 等）からローディング関心を
/// 分離し、責務を明確にするためのプロトコル。
@MainActor
public protocol PhotoLoading: AnyObject {
    associatedtype Item: PhotoItem

    func thumbnail(for item: Item) async -> UIImage?
    /// Size-aware variant. Conformers may override this to pass the actual cell pixel size
    /// to the underlying image loader, avoiding over-fetching.
    func thumbnail(for item: Item, targetSize: CGSize) async -> UIImage?
    func fullImage(for item: Item) async -> UIImage?

    /// スクロール先のサムネイルを先読みする。既定は逐次取得（バッチ系ソースはバッチに集約される）。
    /// `LocalPhotoStore` は `PHCachingImageManager` で上書きする。
    func prefetch(_ items: [Item], targetSize: CGSize)

    /// 撮影地の座標を解決する。既定は `item.coordinate`。
    /// Dropbox は同期時に取れていない場合があるため、必要なら単発取得で補完する。
    func location(for item: Item) async -> CLLocationCoordinate2D?

    /// 元画像から EXIF 等の主要メタ情報を抽出する（詳細画面の情報パネル用）。既定は nil。
    func metadata(for item: Item) async -> PhotoExifInfo?
}

public extension PhotoLoading {
    func thumbnail(for item: Item, targetSize: CGSize) async -> UIImage? {
        await thumbnail(for: item)
    }

    /// 既定の先読み: 低優先度で順次サムネイル取得をキックする（取得結果はキャッシュに乗る）。
    func prefetch(_ items: [Item], targetSize: CGSize) {
        Task(priority: .utility) {
            for item in items {
                guard !Task.isCancelled else { break }
                _ = await thumbnail(for: item, targetSize: targetSize)
                await Task.yield()
            }
        }
    }

    /// 既定の位置解決: アイテムが持つ座標をそのまま返す。
    func location(for item: Item) async -> CLLocationCoordinate2D? {
        item.coordinate
    }

    /// 既定: メタ情報なし。
    func metadata(for item: Item) async -> PhotoExifInfo? { nil }
}
#endif
