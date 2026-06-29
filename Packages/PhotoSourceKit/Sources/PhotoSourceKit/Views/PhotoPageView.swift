#if canImport(UIKit)
import SwiftUI
import MosaicSupport

/// Generic full-screen paging view. Swipe horizontally to navigate between items.
/// 1 ページの中身は `FullPhotoView`、その情報パネルは `PhotoInfoPanel`（別ファイル）。
/// 上部に日付（＋場所が分かればその下に地名）を出す。ナビバーは隠してカスタム戻るボタンにし、
/// ラベルを最上部のアクティビティバーの**すぐ下**へ寄せる（ナビバーぶんの隙間をなくす）。
public struct PhotoPageView<Store: PhotoStore>: View {
    let store: Store
    /// 現在のページを **item.id** で保持する（C/E）。`Array(items.enumerated())` の
    /// 6.7万件タプル配列を作らず、`ForEach(store.items)` を直接回す。
    @State private var currentID: Store.Item.ID
    /// 現在ページの地名（位置情報があれば解決して日付の下に表示する）。
    @State private var currentPlace: String?
    @Environment(\.dismiss) private var dismiss

    public init(store: Store, startID: Store.Item.ID) {
        self.store = store
        self._currentID = State(initialValue: startID)
    }

    private var currentItem: Store.Item? {
        store.items.first { $0.id == currentID }
    }

    private func topLabel(_ item: Store.Item) -> String? {
        // 撮影日時は日付＋時刻（yyyy-MM-dd HH:mm）。アルバム等で displayTitle があればそれを優先。
        item.displayTitle ?? item.captureDate.map(DisplayDate.dateTime)
    }

    public var body: some View {
        // ナビバーを隠すことで上部ラベルの基準（安全領域上端）＝アクティビティバー位置になり、
        // 「バーのすぐ下」に寄せられる（ナビバーが入ると 1 段ぶん下がってしまうため）。
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

            topControls
        }
        .toolbar(.hidden, for: .navigationBar)
        // A: 写真ビュー表示中（＝タップ直後の遷移を含む）は背景 CLIP 埋め込みを止め、
        //    遷移・デコードに CPU/ANE を明け渡す。閉じると自動再開。
        .onAppear { BackgroundActivityMonitor.shared.isViewingPhoto = true; schedulePrefetch() }
        .onDisappear { BackgroundActivityMonitor.shared.isViewingPhoto = false }
        // 現在ページの位置情報→地名を解決（オフライン DB なので即時）。ページ切替で更新。
        .task(id: currentID) { await resolveCurrentPlace() }
        // Pre-fetch the next page as soon as the page view opens, so photos are
        // ready before the user swipes near the end.
        .task {
            if store.hasMore {
                await store.loadMore()
            }
        }
        // Also trigger when swiping within 20 photos of the end. hasMore は通常 false
        // （ページングなし）なので、その場合は firstIndex の走査も走らない。
        // あわせて D: 次ページのフル画像を先読みして、スワイプ時の黒画面待ちを減らす。
        .onChange(of: currentID) { _, newID in
            schedulePrefetch()
            guard store.hasMore,
                  let index = store.items.firstIndex(where: { $0.id == newID }) else { return }
            if index >= store.items.count - 20 {
                Task { await store.loadMore() }
            }
        }
    }

    /// D: 現在ページの**次の 1 枚だけ**を、少し遅らせてフル画像先読みする。
    /// 即時に前後2枚を取りに行くと、表示中の画像のダウンロードと帯域を食い合って逆に遅くなるため、
    /// 表示画像を先に通してから（1.2s 後・まだ同じページにいれば）次の1枚だけ取りに行く。
    /// クラウドはバイト取得・保存、ローカルは no-op。
    private func schedulePrefetch() {
        let pageID = currentID
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard pageID == currentID,
                  let idx = store.items.firstIndex(where: { $0.id == currentID }),
                  store.items.indices.contains(idx + 1) else { return }
            store.prefetchFullImage(for: store.items[idx + 1])
        }
    }

    /// 上部のオーバーレイ：左上にカスタム戻るボタン、中央にアクティビティバー直下の日付＋場所。
    @ViewBuilder
    private var topControls: some View {
        ZStack(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.top, 4)

            if let item = currentItem, let label = topLabel(item) {
                VStack(spacing: 2) {
                    Text(label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    if let place = currentPlace, !place.isEmpty {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 24)   // 安全領域上端（=アクティビティバー）のすぐ下。バーと重ねない
                .allowsHitTesting(false)
            }
        }
    }

    /// 現在ページの位置情報を地名へ解決する。位置が無ければ場所行は出さない。
    /// C: `cachedLocation` を使い、座標が未取得でも `get_metadata` の往復を起こさない
    ///    （分かっていれば出す／無ければ出さない）。
    private func resolveCurrentPlace() async {
        currentPlace = nil
        guard let item = currentItem,
              let coordinate = await store.cachedLocation(for: item) else { return }
        let resolved = await PlaceNameResolver.shared.placeName(for: coordinate)
        // 解決中に別ページへ移ったら破棄（task(id:) で基本キャンセルされるが二重防止）。
        if !Task.isCancelled { currentPlace = resolved }
    }
}
#endif
