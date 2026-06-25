#if canImport(UIKit)
import SwiftUI

// MARK: - Zoom ladder

/// グリッドの表示モード。
private enum GridDisplayMode {
    case dense        // 連続グリッド（日付ヘッダーなし）
    case monthGroup   // 月ヘッダー付き
    case yearGroup    // 年ヘッダー付き
}

/// ズーム1段階＝（表示モード, 1行あたりの列数）。
/// 大きい写真（1列）→ … → 最も多い 60 列まで。ピンチとスライダーの両方がこのラダーを進める。
private struct ZoomLevel {
    let mode: GridDisplayMode
    let cols: Int
}

private let zoomLevels: [ZoomLevel] = [
    ZoomLevel(mode: .dense, cols: 1),
    ZoomLevel(mode: .dense, cols: 2),
    ZoomLevel(mode: .dense, cols: 3),
    ZoomLevel(mode: .dense, cols: 4),
    ZoomLevel(mode: .dense, cols: 5),
    ZoomLevel(mode: .monthGroup, cols: 15),
    ZoomLevel(mode: .yearGroup, cols: 30),
    ZoomLevel(mode: .yearGroup, cols: 50),   // 最も多く並べる表示
]

// MARK: - Grid view

/// 写真グリッドの合成ルート。ズーム段階（列数ラダー）の状態を持ち、実レイアウトは
/// `DenseGridView` / `GroupedGridView` に委譲する。ピンチとスライダーの両方で段階を変えられる。
public struct PhotoGridView<Store: PhotoStore>: View {
    let store: Store
    /// ラダーのインデックス。既定はインデックス 2（dense 3 列）。
    @AppStorage(GridSettingsKeys.zoomLevel) private var zoomLevel = 2

    public init(store: Store) { self.store = store }

    private var level: ZoomLevel {
        zoomLevels[min(max(0, zoomLevel), zoomLevels.count - 1)]
    }

    // MARK: Body

    public var body: some View {
        content
            // item.id で遷移する（C）。index 依存をやめ、巨大な enumerated 配列を作らない。
            .navigationDestination(for: Store.Item.ID.self) { id in
                PhotoPageView(store: store, startID: id)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch level.mode {
        case .dense:
            DenseGridView(store: store, columnCount: level.cols, onPinch: onPinch)
        case .monthGroup:
            GroupedGridView(store: store, colCount: level.cols, grouping: .month, onPinch: onPinch)
        case .yearGroup:
            GroupedGridView(store: store, colCount: level.cols, grouping: .year, onPinch: onPinch)
        }
    }

    // MARK: Pinch handler

    /// ピンチでラダーを1段階ずつ移動する（pinch in＝拡大＝列を減らす / pinch out＝縮小＝列を増やす）。
    private func onPinch(_ scale: CGFloat) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > 1.0 {
                zoomLevel = max(0, zoomLevel - 1)
            } else {
                zoomLevel = min(zoomLevels.count - 1, zoomLevel + 1)
            }
        }
    }
}
#endif
