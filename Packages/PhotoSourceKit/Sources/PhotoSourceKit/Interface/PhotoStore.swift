#if canImport(UIKit)
import Observation
import UIKit

/// Source-agnostic interface for a photo collection.
///
/// Implement `start()` to perform initial loading (permission request, API call, etc.)
/// and `retry()` to recover from a `failed` state.
/// `state` must be a computed property so SwiftUI tracks its dependencies across object boundaries.
///
/// Pagination: sources that load in pages expose `hasMore` / `isLoadingMore` and implement
/// `loadMore()`. Sources that load everything at once keep the default no-op implementations.
///
/// アイテム単位の画像/メタ情報取得は `PhotoLoading` に分離されている。`PhotoStore` はそれを
/// 精緻化するため、`Store: PhotoStore` の制約だけでローディング系メソッドも利用できる。
@MainActor
public protocol PhotoStore: PhotoLoading, Observable {
    var items: [Item] { get }
    var state: PhotoLoadState { get }
    /// True if there are more items available from the source that have not yet been fetched.
    var hasMore: Bool { get }
    /// True while a `loadMore()` call is in progress.
    var isLoadingMore: Bool { get }

    func start() async
    func retry() async
    /// Fetches the next page of items and appends them to `items`.
    /// No-op when `hasMore` is false or a load is already in progress.
    func loadMore() async
}

/// Default implementations for sources that do not support pagination.
public extension PhotoStore {
    var hasMore: Bool { false }
    var isLoadingMore: Bool { false }
    func loadMore() async { }
    /// ローカル＋クラウドの**混在ソース**か。フィルタの「ソース」欄は混在ビューでのみ意味があるため、
    /// 単一ソース（写真タブ＝端末のみ・クラウドタブ＝Dropbox のみ）では非表示にする。既定 false。
    var isMixedSource: Bool { false }
}
#endif
