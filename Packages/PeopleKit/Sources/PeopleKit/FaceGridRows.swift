import AutoAlbumCore
import Foundation

/// List の行に並べる 1 行ぶん（`id` は先頭要素で決める＝並びが変わっても対応が付く）。
struct OutlierRow: Identifiable {
    let id: String
    let faces: [PersonOutlierFace]
}

/// グリッドを**自分で行に刻む**ための純ロジック。
///
/// ⚠️ SwiftUI の `List` の行の中に `LazyVGrid` を置くと、件数が増えたところで落ちる
/// （実機 8/31 21:59: 「さらに表示」で 24→48 にした直後、
/// `UpdateCoalescingCollectionView.layoutSubviews` → `_updateVisibleCellsNow` の再入 →
/// `_assertionFailure`）。List は UICollectionView 実装で、行の中の遅延グリッドが
/// 高さを決めるたびにレイアウトを無効化するため、再計算が収束しない。
/// 行を固定列数で刻めば高さが確定し、何件並べてもループにならない。
enum FaceGridRows {

    /// `columns` 件ずつに分ける（順序は保つ。端数は最後の行に入る）。
    static func chunked<T>(_ items: [T], columns: Int) -> [[T]] {
        guard columns > 0, !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
    }
}
