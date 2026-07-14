#if canImport(UIKit)
import SwiftUI
import MosaicSupport

// MARK: - Zoom ladder

/// グリッドの表示モード。
private enum GridDisplayMode {
    case dense        // 連続グリッド（日付ヘッダーなし）
    case monthGroup   // 月ヘッダー付き
    case yearGroup    // 年ヘッダー付き
}

/// ズーム1段階＝（表示モード, 1行あたりの列数）。
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

/// 写真グリッドの合成ルート。ズーム段階（列数ラダー）の状態を持ち、実体は `UICollectionView`
/// ベースの `PhotoCollectionView` に委譲する（数万件規模での確実なスクラブ＋性能のため）。
/// ピンチとスライダーの両方でズーム段階を変えられる。
public struct PhotoGridView<Store: PhotoStore>: View {
    let store: Store
    /// 絞り込み条件（お気に入りのみ等・`PhotoSourceContentView` の下部バーから指定）。
    let filter: PhotoFilter
    /// ラダーのインデックス。既定はインデックス 2（dense 3 列）。
    @AppStorage(GridSettingsKeys.zoomLevel) private var zoomLevel = 2
    /// 月グループの密度（1セクションを閉じるまでに貯める行数）。既定 1＝最大密度。
    @AppStorage(GridSettingsKeys.monthSectionRows) private var monthSectionRows = 1
    @Environment(\.photoInteraction) private var photoInteraction
    /// タップで開く写真（item.id）。`navigationDestination(item:)` で詳細へ push する。
    @State private var selectedID: Store.Item.ID?

    public init(store: Store, filter: PhotoFilter = PhotoFilter()) {
        self.store = store
        self.filter = filter
    }

    /// フィルタ適用後の表示アイテム（未フィルタなら store.items をそのまま）。
    private var visibleItems: [Store.Item] { filter.apply(store.items) }

    private var level: ZoomLevel {
        zoomLevels[min(max(0, zoomLevel), zoomLevels.count - 1)]
    }

    private var grouping: PhotoGridGrouping? {
        switch level.mode {
        case .dense:      return nil
        case .monthGroup: return .month
        case .yearGroup:  return .year
        }
    }

    public var body: some View {
        Group {
            if filter.isActive && visibleItems.isEmpty {
                // フィルタで 0 件。空グリッドだと故障に見えるため明示する（お気に入り条件のみのときは
                // ハートの付け方の案内、ソース条件を含むときは汎用メッセージ）。
                if filter.favoritesOnly && filter.source == .all {
                    ContentUnavailableView(L("No favorites"), systemImage: "heart",
                                           description: Text(L("Mark photos with a heart to see them here.")))
                } else {
                    ContentUnavailableView(L("No matching photos"),
                                           systemImage: "line.3.horizontal.decrease.circle",
                                           description: Text(L("Try changing the filter.")))
                }
            } else {
                PhotoCollectionView(
                    store: store,
                    items: visibleItems,
                    columnCount: level.cols,
                    grouping: grouping,
                    monthSectionRows: max(1, monthSectionRows),
                    onPinch: onPinch,
                    onSelect: {
                        PerfTrace.beginScreen("open.photo")   // 計測: タップ→フル表示(onAppear)
                        // A: タップ直後から背景 CLIP 埋め込みを止め、遷移のメインスレッドを空ける。
                        BackgroundActivityMonitor.shared.isViewingPhoto = true
                        selectedID = $0
                    },
                    onScrubbingChange: { active in photoInteraction?(active) }   // G: 背景処理を譲る
                )
                .ignoresSafeArea(.container, edges: .horizontal)
            }
        }
        // グリッドが見えている＝閲覧していない。フラグの取りこぼし（遷移失敗等）も確実に解除する。
        .onAppear { BackgroundActivityMonitor.shared.isViewingPhoto = false }
        .navigationDestination(item: $selectedID) { id in
            // フィルタ中はフル画面のスワイプ送りも**フィルタ後の並び**でページングする
            // （未フィルタ時は nil＝store.items を直接参照し、追加ロードも従来どおり）。
            PhotoPageView(store: store, startID: id,
                          pagingItems: filter.isActive ? visibleItems : nil)
                .perfScreenEnd("open.photo")   // 計測: フル表示の onAppear で所要を確定
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
