#if canImport(UIKit)
import SwiftUI

/// Generic full-screen paging view. Swipe horizontally to navigate between items.
/// 1 ページの中身は `FullPhotoView`、その情報パネルは `PhotoInfoPanel`（別ファイル）。
/// Toolbar shows `displayTitle` when available, otherwise formats `captureDate`.
public struct PhotoPageView<Store: PhotoStore>: View {
    let store: Store
    /// 現在のページを **item.id** で保持する（C/E）。`Array(items.enumerated())` の
    /// 6.7万件タプル配列を作らず、`ForEach(store.items)` を直接回す。
    @State private var currentID: Store.Item.ID

    public init(store: Store, startID: Store.Item.ID) {
        self.store = store
        self._currentID = State(initialValue: startID)
    }

    private var currentItem: Store.Item? {
        store.items.first { $0.id == currentID }
    }

    private func topLabel(_ item: Store.Item) -> String? {
        item.displayTitle ?? item.captureDate.map(DisplayDate.ymd)
    }

    public var body: some View {
        // ZStack(.top)＝**安全領域の上端**基準。写真(TabView)は ignoresSafeArea で全画面、
        // 日付はその上端からわずかに下げて最上部のアクティビティバーの**下**へ置く
        // （中央に出して写真を遮らない／バーと重ねない）。
        ZStack(alignment: .top) {
            TabView(selection: $currentID) {
                ForEach(store.items) { item in
                    FullPhotoView(store: store, item: item)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .ignoresSafeArea()

            if let item = currentItem, let label = topLabel(item) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .padding(.top, 24)   // 安全領域上端（=バー位置）の少し下。バー直下に寄せる
                    .allowsHitTesting(false)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Pre-fetch the next page as soon as the page view opens, so photos are
        // ready before the user swipes near the end.
        .task {
            if store.hasMore {
                await store.loadMore()
            }
        }
        // Also trigger when swiping within 20 photos of the end. hasMore は通常 false
        // （ページングなし）なので、その場合は firstIndex の走査も走らない。
        .onChange(of: currentID) { _, newID in
            guard store.hasMore,
                  let index = store.items.firstIndex(where: { $0.id == newID }) else { return }
            if index >= store.items.count - 20 {
                Task { await store.loadMore() }
            }
        }
    }
}
#endif
