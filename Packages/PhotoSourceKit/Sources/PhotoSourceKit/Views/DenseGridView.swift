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

    @Environment(\.photoInteraction) private var photoInteraction
    /// スクラブ中（A）／高速スクロール中（R3）。どちらかの間は取得・先読み・背景処理を止める。
    @State private var isScrubbing = false
    @State private var isFastScrolling = false
    // 先読みの合体スロットリング（B）。最新の先頭 index を保持し、~120ms で1回だけ実行する。
    @State private var pendingPrefetchIndex: Int?
    @State private var prefetchScheduled = false

    /// ユーザーが能動操作中か（スクラブ or 高速スクロール）。
    private var interacting: Bool { isScrubbing || isFastScrolling }

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
                            // ナビゲーションは index ではなく item.id（C）。並べ替え・件数変化に頑健。
                            NavigationLink(value: item.id) {
                                ThumbnailCell(store: store, item: item, side: cellSide, paused: interacting)
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
                .defaultScrollAnchor(.bottom)
                // R3: 高速スクロール中は取得・先読み・背景処理を止める。
                .pauseOnFastScroll { isFastScrolling = $0 }
                // 縦スクロール用スクラバー（写真が多いときだけ）。ドラッグ位置に比例してジャンプ。
                .overlay(alignment: .trailing) {
                    if store.items.count > 60 {
                        VerticalScrubber(onScrub: { fraction in
                            let idx = Int((fraction * Double(store.items.count - 1)).rounded())
                            if store.items.indices.contains(idx) {
                                proxy.scrollTo(store.items[idx].id, anchor: .top)
                            }
                        }, onActiveChange: { active in
                            isScrubbing = active   // A: 取得停止
                        })
                    }
                }
                // G: 操作（スクラブ/高速スクロール）の開始・終了で背景 CLIP 埋め込みを譲る/再開。
                .onChange(of: interacting) { _, active in
                    photoInteraction?(active)
                }
            }
        }
    }

    // MARK: Prefetch

    /// 先読みを ~120ms に1回へ合体する（B）。連続スクロールで毎行 `store.prefetch` を投げて
    /// Task を量産しないようにし、スクラブ中は完全に停止する（A）。
    private func requestPrefetch(from index: Int, cols: Int) {
        guard !interacting else { return }
        pendingPrefetchIndex = index
        guard !prefetchScheduled else { return }
        prefetchScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            prefetchScheduled = false
            guard !interacting, let idx = pendingPrefetchIndex else { return }
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
#endif
