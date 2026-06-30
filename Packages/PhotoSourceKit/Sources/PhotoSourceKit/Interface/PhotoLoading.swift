#if canImport(UIKit)
import CoreLocation
import UIKit

// アイテム単位の画像・メタ情報ローディングを、関心ごとの小さなプロトコルに分割する（ISP）。
// すべて同じ `associatedtype Item` を共有し、`PhotoLoading` がそれらを合成する。
// `PhotoStore: PhotoLoading` の既存コードは従来どおり全メソッドを利用できる（合成のため不変）。
// 各既定実装はそれぞれのサブプロトコルの extension に置く。

/// サムネイルの取得と先読み。
@MainActor
public protocol PhotoThumbnailing: AnyObject {
    associatedtype Item: PhotoItem
    func thumbnail(for item: Item) async -> UIImage?
    /// Size-aware variant. Conformers may override this to pass the actual cell pixel size
    /// to the underlying image loader, avoiding over-fetching.
    func thumbnail(for item: Item, targetSize: CGSize) async -> UIImage?
    /// スクロール先のサムネイルを先読みする。既定は逐次取得（バッチ系ソースはバッチに集約される）。
    /// `LocalPhotoStore` は `PHCachingImageManager` で上書きする。
    func prefetch(_ items: [Item], targetSize: CGSize)
    /// 画面外へスクロールした先読みを取り消す（無駄な取得を止める）。既定は no-op。
    /// `DropboxPhotoStore` は未取得の先読みをキューから破棄する。
    func cancelPrefetch(_ items: [Item])
}

/// フル画像の取得と先読み。
@MainActor
public protocol PhotoFullImaging: AnyObject {
    associatedtype Item: PhotoItem
    func fullImage(for item: Item) async -> UIImage?
    /// フル画像を**先読み**してキャッシュへ載せる（前後ページの体感改善）。既定は no-op。
    /// `DropboxPhotoStore` はデコードせずバイト列だけ取得・保存する軽量実装で上書きする。
    func prefetchFullImage(for item: Item)
}

/// 撮影地の座標解決。
@MainActor
public protocol PhotoLocating: AnyObject {
    associatedtype Item: PhotoItem
    /// 撮影地の座標を解決する。既定は `item.coordinate`。
    /// Dropbox は同期時に取れていない場合があるため、必要なら単発取得で補完する。
    func location(for item: Item) async -> CLLocationCoordinate2D?
    /// **ネット取得を伴わない**座標解決。すでに分かっている座標だけを返し、未取得なら nil。
    /// フル表示の場所ラベルのように「分かれば出す／無ければ出さない」用途で、開くたびの
    /// `get_metadata` 往復を避けるために使う。既定は `location(for:)`（ローカルは即時）。
    func cachedLocation(for item: Item) async -> CLLocationCoordinate2D?
}

/// EXIF 等のメタ情報抽出（詳細画面の情報パネル用）。
@MainActor
public protocol PhotoMetadataProviding: AnyObject {
    associatedtype Item: PhotoItem
    /// 元画像から EXIF 等の主要メタ情報を抽出する。既定は nil。
    func metadata(for item: Item) async -> PhotoExifInfo?
}

/// お気に入りの書き込み（端末写真のみ対応）。
@MainActor
public protocol PhotoFavoriting: AnyObject {
    associatedtype Item: PhotoItem
    /// お気に入りを設定する。成功で true。既定は no-op で false（非対応）。
    /// `LocalPhotoStore` が PhotoKit へ書き込む実装で上書きする。
    func setFavorite(_ item: Item, _ isFavorite: Bool) async -> Bool
}

/// 上記の合成。`PhotoStore` が精緻化するため、`Store: PhotoStore` の既存コードはそのまま
/// 全メソッドを利用できる。コレクション/状態/ライフサイクル（`items` / `state` / `start` 等）
/// からローディング関心を分離し、責務を明確にするためのプロトコル群。
@MainActor
public protocol PhotoLoading: PhotoThumbnailing, PhotoFullImaging, PhotoLocating,
                              PhotoMetadataProviding, PhotoFavoriting {}

// MARK: - Defaults

public extension PhotoThumbnailing {
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

    /// 既定: 先読みのキャンセルは何もしない（バッチ系ソースのみ上書き）。
    func cancelPrefetch(_ items: [Item]) {}
}

public extension PhotoFullImaging {
    /// 既定: フル画像の先読みは何もしない（ローカルは PHImageManager が高速なため不要）。
    func prefetchFullImage(for item: Item) {}
}

public extension PhotoLocating {
    /// 既定の位置解決: アイテムが持つ座標をそのまま返す。
    func location(for item: Item) async -> CLLocationCoordinate2D? {
        item.coordinate
    }

    /// 既定: ネット取得を伴わない座標は通常の `location` に委譲（ローカルは即時・ネット不使用）。
    /// ネット往復し得るソース（Dropbox）はこれを上書きしてキャッシュ済みのみ返す。
    func cachedLocation(for item: Item) async -> CLLocationCoordinate2D? {
        await location(for: item)
    }
}

public extension PhotoMetadataProviding {
    /// 既定: メタ情報なし。
    func metadata(for item: Item) async -> PhotoExifInfo? { nil }
}

public extension PhotoFavoriting {
    /// 既定: お気に入りの書き込みに非対応（クラウド等）。false を返す。
    func setFavorite(_ item: Item, _ isFavorite: Bool) async -> Bool { false }
}
#endif
