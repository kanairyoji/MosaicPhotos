#if canImport(UIKit)
import SwiftUI

/// Dense モードのグリッド。`LazyVGrid` を `ScrollView` に直接配置して確実に lazy 描画する。
///
/// ⚠️ セルに確定した正方形サイズを与えるため GeometryReader で実幅を取得する。
/// 各セルを .fixed カラム + 固定フレームにして行高を確定させ、推定誤差を消す。
/// 行高が確定するため、スクラバーはコンテンツ高（行数×セル高）から**正確なスクロールオフセット**を
/// 計算でき、`ScrollPosition`（iOS18+）でどんな大ジャンプも確実に飛べる（`scrollTo(id:)` は
/// 未実体化の遠い項目へ飛べず、6.7万件規模の大ジャンプで止まるため使わない）。
struct DenseGridView<Store: PhotoStore>: View {
    let store: Store
    let columnCount: Int
    let onPinch: (CGFloat) -> Void

    private let spacing: CGFloat = 2

    @Environment(\.photoInteraction) private var photoInteraction
    /// スクラブ中はサムネ取得・先読み・背景処理を止める（A）。
    @State private var isScrubbing = false
    // 先読みの合体スロットリング（B）。最新の先頭 index を保持し、~120ms で1回だけ実行する。
    @State private var pendingPrefetchIndex: Int?
    @State private var prefetchScheduled = false

    var body: some View {
        let cols = max(1, columnCount)
        GeometryReader { geo in
            let cellSide = max(1, (geo.size.width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
            let contentHeight = denseContentHeight(count: store.items.count, cols: cols, cellSide: cellSide)
            Group {
                if #available(iOS 18.0, *) {
                    OffsetScrubScroll(
                        showScrubber: store.items.count > 60,
                        contentHeight: contentHeight,
                        viewportHeight: geo.size.height,
                        isScrubbing: $isScrubbing
                    ) {
                        gridContent(cols: cols, cellSide: cellSide)
                    }
                } else {
                    legacyScroll(cols: cols, cellSide: cellSide)
                }
            }
            // G: スクラブの開始・終了で背景 CLIP 埋め込みを譲る/再開。
            .onChange(of: isScrubbing) { _, active in
                photoInteraction?(active)
            }
        }
    }

    // MARK: - Shared grid content

    @ViewBuilder
    private func gridContent(cols: Int, cellSide: CGFloat) -> some View {
        let fixedColumns = Array(repeating: GridItem(.fixed(cellSide), spacing: spacing), count: cols)
        LazyVGrid(columns: fixedColumns, spacing: spacing) {
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                // ナビゲーションは index ではなく item.id（C）。並べ替え・件数変化に頑健。
                NavigationLink(value: item.id) {
                    ThumbnailCell(store: store, item: item, side: cellSide, paused: isScrubbing)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if store.hasMore && index >= store.items.count - 20 {
                        Task { await store.loadMore() }
                    }
                    if index % cols == 0 { requestPrefetch(from: index, cols: cols) }
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

    /// 等間隔セルからコンテンツ高を厳密計算する（スクラバーのオフセット算出用）。
    private func denseContentHeight(count: Int, cols: Int, cellSide: CGFloat) -> CGFloat {
        guard count > 0, cols > 0 else { return 0 }
        let rows = (count + cols - 1) / cols
        return CGFloat(rows) * cellSide + CGFloat(max(0, rows - 1)) * spacing
    }

    // MARK: - Legacy scroll (iOS < 18 フォールバック。実機 iOS26 では使われない)

    @ViewBuilder
    private func legacyScroll(cols: Int, cellSide: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                gridContent(cols: cols, cellSide: cellSide)
            }
            .defaultScrollAnchor(.bottom)
            .overlay(alignment: .trailing) {
                if store.items.count > 60 {
                    VerticalScrubber(onScrub: { fraction in
                        let idx = Int((fraction * Double(store.items.count - 1)).rounded())
                        if store.items.indices.contains(idx) {
                            proxy.scrollTo(store.items[idx].id, anchor: .top)
                        }
                    }, onActiveChange: { active in
                        isScrubbing = active
                    })
                }
            }
        }
    }

    // MARK: - Prefetch

    /// 先読みを ~120ms に1回へ合体する（B）。連続スクロールで毎行 `store.prefetch` を投げて
    /// Task を量産しないようにし、スクラブ中は完全に停止する（A）。
    private func requestPrefetch(from index: Int, cols: Int) {
        guard !isScrubbing else { return }
        pendingPrefetchIndex = index
        guard !prefetchScheduled else { return }
        prefetchScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            prefetchScheduled = false
            guard !isScrubbing, let idx = pendingPrefetchIndex else { return }
            pendingPrefetchIndex = nil
            runPrefetch(from: idx, cols: cols)
        }
    }

    /// `index + 1` から数画面ぶんを先読みする。実際の先読み方法は `store.prefetch` に委譲
    /// （ローカルは PHCachingImageManager、それ以外は逐次取得）。
    private func runPrefetch(from index: Int, cols: Int) {
        let budget = min(cols * 6, 120)
        let prefetchEnd = min(index + budget, store.items.count)
        guard index + 1 < prefetchEnd else { return }
        let items = Array(store.items[(index + 1)..<prefetchEnd])
        let scale = UIScreen.main.scale
        let side = UIScreen.main.bounds.width / CGFloat(cols) * scale
        store.prefetch(items, targetSize: CGSize(width: side, height: side))
    }
}

// MARK: - Offset-based scrubbing scroll (iOS 18+)

/// `ScrollPosition` を使ってスクロールオフセットを直接制御する ScrollView ラッパー。
/// スクラバーは `fraction × 最大オフセット` へジャンプするため、未実体化の遠い項目でも
/// 確実にスクロールできる（`scrollTo(id:)` の大ジャンプ不能問題を回避）。
@available(iOS 18.0, *)
private struct OffsetScrubScroll<Content: View>: View {
    let showScrubber: Bool
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    @Binding var isScrubbing: Bool
    @ViewBuilder let content: Content

    // タイムラインは下端が最新。初期位置は末尾（bottom）。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            content
        }
        .scrollPosition($scrollPosition)
        .overlay(alignment: .trailing) {
            if showScrubber {
                VerticalScrubber(onScrub: { fraction in
                    let maxOffset = max(0, contentHeight - viewportHeight)
                    // fraction: 0=先頭(top) … 1=末尾(bottom)。オフセットで直接ジャンプ。
                    scrollPosition.scrollTo(y: fraction * maxOffset)
                }, onActiveChange: { active in
                    isScrubbing = active   // A: 取得停止
                })
            }
        }
    }
}
#endif
