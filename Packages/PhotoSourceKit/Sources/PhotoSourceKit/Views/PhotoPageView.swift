#if canImport(UIKit)
import SwiftUI
import MosaicSupport

/// Generic full-screen paging view. Swipe horizontally to navigate between items.
/// 1 ページの中身は `FullPhotoView`、その情報パネルは `PhotoInfoPanel`（別ファイル）。
/// 上部に日付（＋場所が分かればその下に地名）を出す。ナビバーは隠してカスタム戻るボタンにし、
/// ラベルを最上部のアクティビティバーの**すぐ下**へ寄せる（ナビバーぶんの隙間をなくす）。
///
/// ★ ページングは**現在ページ周辺だけを生成するウィンドウ方式**。`.page` スタイルの `TabView` は
///   遅延生成されないため、`ForEach(store.items)` を直接回すと 6.7 万件ぶんのページを毎回構築して
///   タップ→表示が十数秒固まる。現在 index の前後 `windowRadius` 件だけを `TabView` に渡し、端へ
///   近づいたらウィンドウを中央へ寄せ直す（選択中の写真は常にウィンドウ内なので正しく表示される）。
public struct PhotoPageView<Store: PhotoStore>: View {
    let store: Store
    /// ページング対象の固定リスト（フィルタ中のグリッドから渡される）。nil なら store.items を直接参照。
    /// 固定リストのときは追加ロード（loadMore）トリガを行わない（スナップショットのため）。
    private let pagingItems: [Store.Item]?
    /// 現在のページを **item.id** で保持する。
    @State private var currentID: Store.Item.ID
    /// 生成するウィンドウの開始 index（allItems に対する下限）。
    @State private var windowLowerBound: Int
    /// 現在ページの地名（位置情報があれば解決して日付の下に表示する）。
    @State private var currentPlace: String?
    /// お気に入りの楽観反映（タップ直後に UI を即更新し、書き込み失敗時のみ戻す）。
    @State private var favOverride: [Store.Item.ID: Bool] = [:]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.faceHighlightProvider) private var faceHighlightProvider
    @Environment(\.photoUsageEvent) private var photoUsageEvent
    /// 顔ハイライト（人物アルバムのみ）。ページ送りしても維持する画面単位のトグル。
    @State private var showFaceHighlights = false
    /// 没入モード（写真のシングルタップで切替）。上下のバー＋ステータスバーを隠して写真だけにする。
    /// ページ送りしても維持する（写真を次々見るモードのため）。画面を閉じればリセット。
    @State private var isImmersive = false
    /// 共有シートに渡すフル画像（ロード完了で表示）。
    @State private var shareItem: ShareImageItem?
    @State private var isPreparingShare = false

    /// ウィンドウ半径（前後それぞれに生成する枚数）。中央±30＝最大61ページだけ構築する。
    private static var windowRadius: Int { 30 }
    /// 端から何枚以内に近づいたらウィンドウを再センタリングするか。
    private static var recenterMargin: Int { 8 }

    public init(store: Store, startID: Store.Item.ID, pagingItems: [Store.Item]? = nil) {
        self.store = store
        self.pagingItems = pagingItems
        self._currentID = State(initialValue: startID)
        let items = pagingItems ?? store.items
        let startIndex = items.firstIndex(where: { $0.id == startID }) ?? 0
        self._windowLowerBound = State(initialValue: max(0, startIndex - Self.windowRadius))
    }

    /// ページング対象（固定リスト or store.items）。
    private var allItems: [Store.Item] { pagingItems ?? store.items }

    /// `TabView` に渡す現在ウィンドウのスライス（全 67k ではなく中央±radius のみ）。
    private var windowItems: ArraySlice<Store.Item> {
        let items = allItems
        guard !items.isEmpty else { return items[items.startIndex..<items.startIndex] }
        let lo = min(max(0, windowLowerBound), max(0, items.count - 1))
        let hi = min(items.count, lo + Self.windowRadius * 2 + 1)
        return items[lo..<hi]
    }

    private var currentItem: Store.Item? {
        allItems.first { $0.id == currentID }
    }

    /// 現在ページのお気に入り状態（楽観反映があればそれを優先）。
    private var currentIsFavorite: Bool {
        if let override = favOverride[currentID] { return override }
        return currentItem?.isFavorite ?? false
    }

    /// ハートのタップでお気に入りを付け外しする。UI は即時更新し、書き込み失敗時のみ戻す。
    private func toggleFavorite() {
        guard let item = currentItem, item.supportsFavorite else { return }
        let newValue = !currentIsFavorite
        favOverride[currentID] = newValue
        Task {
            let ok = await store.setFavorite(item, newValue)
            if !ok { favOverride[currentID] = !newValue }
        }
    }

    private func topLabel(_ item: Store.Item) -> String? {
        // 撮影日時は日付＋時刻（yyyy-MM-dd HH:mm）。アルバム等で displayTitle があればそれを優先。
        // 無意味な日付（EXIF 欠落・0・1980 等）は「日時不明」と表示する（変な日時にしない）。
        if let title = item.displayTitle { return title }
        if let date = DisplayDate.meaningful(item.captureDate) { return DisplayDate.dateTime(date) }
        return L("Date unknown")
    }

    public var body: some View {
        // ナビバーを隠すことで上部ラベルの基準（安全領域上端）＝アクティビティバー位置になり、
        // 「バーのすぐ下」に寄せられる（ナビバーが入ると 1 段ぶん下がってしまうため）。
        ZStack {
            TabView(selection: $currentID) {
                ForEach(windowItems) { item in
                    FullPhotoView(store: store, item: item, showFaceHighlights: showFaceHighlights,
                                  onTap: { isImmersive.toggle() })
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black)
            .ignoresSafeArea()

            // 上部＝ナビ（戻る）＋写真情報のみ、下部＝操作（お気に入り/共有/顔）。
            // 他画面（グリッド）が下部操作なので、フル画面もアクションは下部に統一する。
            // 没入モード中はフェードで隠す（タップも透過させ、写真だけの表示にする）。
            VStack(spacing: 0) {
                topControls
                Spacer()
                bottomControls
            }
            .opacity(isImmersive ? 0 : 1)
            .allowsHitTesting(!isImmersive)
            .animation(.easeInOut(duration: 0.2), value: isImmersive)
        }
        .statusBarHidden(isImmersive)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $shareItem) { item in
            ActivityShareSheet(image: item.image) { completed in
                guard completed, let photoUsageEvent else { return }
                let id = "\(currentID)"
                Task { await photoUsageEvent(.share, id) }
            }
        }
        // A: 写真ビュー表示中（＝タップ直後の遷移を含む）は背景 CLIP 埋め込みを止め、
        //    遷移・デコードに CPU/ANE を明け渡す。閉じると自動再開。
        .onAppear {
            BackgroundActivityMonitor.shared.isViewingPhoto = true
            schedulePrefetch()
        }
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
        .onChange(of: currentID) { _, newID in
            recenterWindowIfNeeded(around: newID)   // ウィンドウを中央へ寄せ直す（端に近づいたら）
            schedulePrefetch()                       // D: 次ページのフル画像先読み
            // ページング末尾近く（20枚以内）で追加ロード。hasMore は通常 false。
            // 固定リスト（フィルタ中）はスナップショットなので追加ロードしない。
            guard pagingItems == nil, store.hasMore,
                  let index = store.items.firstIndex(where: { $0.id == newID }) else { return }
            if index >= store.items.count - 20 {
                Task { await store.loadMore() }
            }
        }
    }

    /// スワイプで現在 index が端へ近づいたら、ウィンドウを現在 index 中心に寄せ直す。
    /// 選択中の `currentID` は新ウィンドウ内に必ず含まれるので、表示中の写真は維持される。
    private func recenterWindowIfNeeded(around id: Store.Item.ID) {
        let items = allItems
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let lo = windowLowerBound
        let hi = min(items.count, lo + Self.windowRadius * 2 + 1)
        if idx - lo < Self.recenterMargin || (hi - 1) - idx < Self.recenterMargin {
            let maxLo = max(0, items.count - (Self.windowRadius * 2 + 1))
            windowLowerBound = max(0, min(idx - Self.windowRadius, maxLo))
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
            let items = allItems
            guard pageID == currentID,
                  let idx = items.firstIndex(where: { $0.id == currentID }),
                  items.indices.contains(idx + 1) else { return }
            store.prefetchFullImage(for: items[idx + 1])
        }
    }

    /// 上部のオーバーレイ：中央にアクティビティバー直下の日付＋場所のみ。
    /// 戻る／アクション（お気に入り/共有/顔）は下部バー（`bottomControls`）へ集約し、他画面と統一する。
    @ViewBuilder
    private var topControls: some View {
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

    /// 下部の操作バー（グリッドと同じ位置・同じ不透明背景＝`.bar`）。左端に戻る、
    /// 右側にお気に入り・共有・顔ハイライト。透過の丸ボタンだと写真に溶けて見えないため、
    /// グリッド下部バーと同じ全幅の不透明バーに載せて視認性を確保する。
    @ViewBuilder
    private var bottomControls: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .imageScale(.large)
                    .accessibilityLabel(L("Back"))
            }
            .padding(.leading, 20)

            Spacer()

            HStack(spacing: 32) {
                if currentItem?.supportsFavorite == true {
                    Button { toggleFavorite() } label: {
                        Image(systemName: currentIsFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(currentIsFavorite ? Color.pink : Color.primary)
                    }
                    .accessibilityLabel(L("Favorite"))
                }
                Button { prepareShare() } label: {
                    if isPreparingShare {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isPreparingShare)
                .accessibilityLabel(L("Share"))
                if faceHighlightProvider != nil {
                    Button { showFaceHighlights.toggle() } label: {
                        Image(systemName: showFaceHighlights ? "face.smiling.inverse" : "face.smiling")
                            .foregroundStyle(showFaceHighlights ? Color.yellow : Color.primary)
                    }
                    .accessibilityLabel(L("Show recognized face"))
                }
            }
            .imageScale(.large)
            .padding(.trailing, 20)
        }
        .frame(height: 49)
        .background(.bar)
    }

    /// 共有の準備: フル画像をロードして共有シートを開く（キャッシュ済みなら即時）。
    private func prepareShare() {
        guard !isPreparingShare, let item = currentItem else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            if let image = await store.fullImage(for: item) {
                shareItem = ShareImageItem(image: image)
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

/// 共有シートに渡す 1 画像（sheet(item:) 用の Identifiable ラッパー）。
private struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// UIActivityViewController の SwiftUI ラッパー。完了ハンドラで「実際に共有したか」を返す
/// （キャンセルはカウントしない）。
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#endif
