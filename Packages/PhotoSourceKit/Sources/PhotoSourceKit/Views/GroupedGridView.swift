#if canImport(UIKit)
import SwiftUI

/// Month/Year グループモードのグリッド。
///
/// `LazyVStack` + `Section` + **`HStack` 行** を使用する。
/// `LazyVGrid` を `LazyVStack` / `Section` 内に置くと `ScrollView` の visible bounds が
/// 伝播されずセルが描画されないため、代わりに `LazyVStack` が個々の `HStack` 行を
/// lazy に生成する構造にする。
///
/// dense モードと同様、セルの一辺を確定値で算出して各セルに固定フレームを与え、
/// 行高を確定させる（推定誤差由来のスクロールジャンプ防止 + 正方形クロップのため）。
struct GroupedGridView<Store: PhotoStore>: View {
    let store: Store
    let colCount: Int
    let grouping: PhotoGridGrouping
    let onPinch: (CGFloat) -> Void

    private let spacing: CGFloat = 2
    // セクションはメインアクタ外で生成して保持（68k 件規模のグルーピングで描画を固めない）。
    @State private var sections: [PhotoGridSection<Store.Item>] = []

    @Environment(\.photoInteraction) private var photoInteraction
    /// スクラブ中（A）／高速スクロール中（R3）。どちらかの間は取得・背景処理を止める。
    @State private var isScrubbing = false
    @State private var isFastScrolling = false

    private var interacting: Bool { isScrubbing || isFastScrolling }

    var body: some View {
        GeometryReader { geo in
            let cellSide = max(1, (geo.size.width - spacing * CGFloat(colCount - 1)) / CGFloat(colCount))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    HStack(spacing: spacing) {
                                        // セルを item.id で識別し、スクラバーの scrollTo(item.id) の対象にする。
                                        ForEach(row.entries, id: \.item.id) { entry in
                                            // ナビゲーションは flatIndex ではなく item.id（C）。
                                            NavigationLink(value: entry.item.id) {
                                                ThumbnailCell(store: store, item: entry.item, side: cellSide,
                                                              paused: interacting)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        // Fill incomplete last row to keep column alignment
                                        if row.entries.count < colCount {
                                            ForEach(0..<(colCount - row.entries.count), id: \.self) { _ in
                                                Color.clear
                                                    .frame(width: cellSide, height: cellSide)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.regularMaterial)
                            }
                        }
                    }
                    .background(PinchRecognizerBridge(onEnded: onPinch))
                }
                .defaultScrollAnchor(.bottom)
                .pauseOnFastScroll(enabled: !isScrubbing) { isFastScrolling = $0 }   // R3（スクラブ中は無効）
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
        // G: 操作（スクラブ/高速スクロール）の開始・終了で背景 CLIP 埋め込みを譲る/再開。
        .onChange(of: interacting) { _, active in
            photoInteraction?(active)
        }
        // items / 粒度 / 列数が変わったときだけ、メインアクタ外でセクションを再構築する。
        .task(id: "\(store.items.count)|\(grouping)|\(colCount)") {
            let snapshot = store.items
            let grouping = grouping
            let colCount = colCount
            sections = await Task.detached(priority: .userInitiated) {
                photoGridSections(items: snapshot, grouping: grouping, colCount: colCount)
            }.value
        }
    }
}
#endif
