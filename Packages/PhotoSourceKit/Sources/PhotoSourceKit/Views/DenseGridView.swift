#if canImport(UIKit)
import SwiftUI

/// Dense モードのグリッド。`LazyVGrid` を `ScrollView` に直接配置して確実に lazy 描画する。
///
/// ⚠️ セルに確定した正方形サイズを与えるため GeometryReader で実幅を取得する。
/// LazyVGrid は行高を「推定」して全体のコンテンツ高を算出するが、万件規模
/// （例: 16,840件 ≒ 5,600行）では推定誤差が累積し、セルが実測されるたびに
/// コンテンツ高が補正される。defaultScrollAnchor(.bottom) は補正のたびにスクロール
/// 位置を再調整するため、読み込み済みセルが画面外へ弾き出されて初回表示が崩れる。
/// 各セルを .fixed カラム + 固定フレームにして行高を確定させ、推定誤差そのものを消す。
struct DenseGridView<Store: PhotoStore>: View {
    let store: Store
    let columnCount: Int
    let onPinch: (CGFloat) -> Void

    private let spacing: CGFloat = 2

    var body: some View {
        let cols = max(1, columnCount)
        GeometryReader { geo in
            let cellSide = max(1, (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
            let fixedColumns = Array(
                repeating: GridItem(.fixed(cellSide), spacing: spacing),
                count: cols
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: fixedColumns, spacing: spacing) {
                        ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(value: index) {
                                ThumbnailCell(store: store, item: item, side: cellSide)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if store.hasMore && index >= store.items.count - 20 {
                                    Task { await store.loadMore() }
                                }
                                prefetchIfNeeded(from: index, cols: cols)
                            }
                        }
                    }
                    .background(PinchRecognizerBridge(onEnded: onPinch))

                    if store.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                .defaultScrollAnchor(.bottom)
                // 縦スクロール用スクラバー（写真が多いときだけ）。ドラッグ位置に比例してジャンプ。
                .overlay(alignment: .trailing) {
                    if store.items.count > 60 {
                        VerticalScrubber { fraction in
                            let idx = Int((fraction * Double(store.items.count - 1)).rounded())
                            if store.items.indices.contains(idx) {
                                proxy.scrollTo(store.items[idx].id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Prefetch

    /// Fires a prefetch for the next ~3 rows starting at `index + 1`.
    /// Only triggers for the first cell in each row to avoid redundant fan-out.
    /// 実際の先読み方法は `store.prefetch` に委譲（ローカルは PHCachingImageManager、
    /// それ以外は逐次取得）。
    private func prefetchIfNeeded(from index: Int, cols: Int) {
        guard index % cols == 0 else { return }  // only first cell per row
        // 先読みウィンドウ。Dropbox は並行バッチ取得（最大4本×25枚）で捌けるので、
        // パイプラインを埋めるために広めに取る（数画面ぶん先読み）。上限で要求爆発を防ぐ。
        let budget = min(cols * 6, 120)
        let prefetchEnd = min(index + budget, store.items.count)
        guard index + 1 < prefetchEnd else { return }
        let items = Array(store.items[(index + 1)..<prefetchEnd])
        let scale = UIScreen.main.scale
        let side = UIScreen.main.bounds.width / CGFloat(cols) * scale
        store.prefetch(items, targetSize: CGSize(width: side, height: side))
    }
}
#endif
