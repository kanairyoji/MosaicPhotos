import DropboxKit
import LocalPhotoKit
import MapKit
import MosaicSupport
import PhotoSourceKit
import PhotosFeatureKit
import SwiftUI

/// 写真の地図ビュー（ADR-127）。撮影地にピンを立て、拡大/縮小で粒度が変わる。
///
/// ⚠️ 設計の要点: ライブラリは 86,000 枚規模なので、**1 枚 1 ピンにはしない**。
/// 可視範囲の写真だけを、ズームで決まるグリッドに畳んで数百ピンに抑える
/// （`PhotoMapClustering`＝純ロジック・テスト済み）。集約はオフメインで行い、
/// メインには完成したピン配列だけを渡す（CLAUDE.md 性能原則 4）。
struct PhotoMapView: View {
    let dropboxStore: DropboxPhotoStore
    let placeScanner: PlaceScanner
    let assetIndex: LocalAssetIndex

    @Environment(\.dismiss) private var dismiss
    /// 座標付き写真の索引（この画面の間だけ持つ。閉じたら解放する）。
    @State private var candidates: [PlaceCandidate] = []
    @State private var pins: [PhotoMapPin] = []
    @State private var camera: MapCameraPosition = .region(Self.mapRegion(.world))
    @State private var isLoading = true
    @State private var loadTask: Task<[PlaceCandidate], Never>?
    /// 集約の世代。領域変更が連続したとき、古い結果で新しい表示を壊さない
    /// （`MergedPhotoStore.rebuildGeneration` と同型）。
    @State private var clusterGeneration = 0
    @State private var clusterTask: Task<Void, Never>?
    @State private var selected: PhotoMapPin?
    /// 代表写真のサムネ（この画面の間だけ持つ）。⚠️ 無いと、地図を動かすたびに同じ写真を
    /// 取り直すことになる——クラウド写真は表示用サムネと同じ回線を使うので、閲覧中の取得を
    /// 押しのけてしまう（ADR-92 と同じ轍）。
    @State private var thumbnails = PhotoMapThumbnailCache()

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                ForEach(pins) { pin in
                    Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                        PhotoMapPinBadge(pin: pin, dropboxStore: dropboxStore,
                                         cache: thumbnails) { selected = pin }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { context in
                recluster(region: Self.region(context.region))
            }
            .overlay(alignment: .top) { emptyHint }
            .busyOverlay(isLoading, text: L("Finding photos with location…"),
                         cancel: (label: L("Cancel"), action: cancelLoad))
            .navigationTitle(L("Map"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Text(verbatim: "\(candidates.count)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .task { await load() }
            .navigationDestination(item: $selected) { pin in
                PhotoMapCellView(pin: pin, dropboxStore: dropboxStore, assetIndex: assetIndex)
            }
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if !isLoading && candidates.isEmpty {
            Label(L("No photos with location found."), systemImage: "mappin.slash")
                .font(.callout)
                .padding(12)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    // MARK: - Loading

    /// 索引を作る（**1 回だけ**）。
    ///
    /// ⚠️ 写真を開いて戻ってきたとき、ここが走り直すと初期位置へカメラが戻ってしまう
    /// （実フィードバック: 「戻ると日本全体になる」）。`.task` は画面の再表示でも走り得るので、
    /// 索引の有無で早期に帰る。索引は画面（`@State`）と寿命を共にするので、
    /// 地図を閉じれば解放される——**押して戻るだけで捨ててはいけない**。
    private func load() async {
        guard candidates.isEmpty, loadTask == nil else { return }
        guard let found = await runCancellable(isBusy: $isLoading, task: $loadTask,
                                               { await placeScanner.locatedCandidates(
                                                   dropboxItems: dropboxStore.items) })
        else { return }
        candidates = found
        // 初期表示は**写真がいちばん多い場所**（国や都市はコードに書かない・ADR-127 追補）。
        if let region = PhotoMapClustering.initialRegion(of: found) {
            camera = .region(Self.mapRegion(region))
            recluster(region: region)
        }
    }

    private func cancelLoad() {
        cancelRunning(isBusy: $isLoading, task: $loadTask)
        dismiss()
    }

    /// 表示範囲が変わったら畳み直す。**オフメインで集約**し、最新世代の結果だけを反映する。
    private func recluster(region: PhotoMapRegion) {
        guard !candidates.isEmpty else { return }
        clusterGeneration &+= 1
        let generation = clusterGeneration
        clusterTask?.cancel()
        let snapshot = candidates
        clusterTask = Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                PhotoMapClustering.pins(candidates: snapshot, region: region)
            }.value
            guard !Task.isCancelled, generation == clusterGeneration else { return }
            pins = fresh
        }
    }

    // MARK: - MapKit との変換

    private static func region(_ region: MKCoordinateRegion) -> PhotoMapRegion {
        PhotoMapRegion(centerLatitude: region.center.latitude,
                       centerLongitude: region.center.longitude,
                       latitudeDelta: region.span.latitudeDelta,
                       longitudeDelta: region.span.longitudeDelta)
    }

    private static func mapRegion(_ region: PhotoMapRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: region.centerLatitude,
                                           longitude: region.centerLongitude),
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta,
                                   longitudeDelta: region.longitudeDelta))
    }
}

/// ピン（代表写真＋件数）。
///
/// ⚠️ クラウド写真のサムネは**表示用サムネと同じ回線**を通る。地図を動かすたびに数十件を
/// 投げると閲覧中の取得を押しのけるので、(1) 出すのは可視ピンぶんだけ（集約で数十に有界）、
/// (2) 一度取ったらセッション内でキャッシュ、(3) ピンが画面から消えたら `task` の
/// キャンセルで取得も止まる、の 3 点で抑える。
private struct PhotoMapPinBadge: View {
    let pin: PhotoMapPin
    let dropboxStore: DropboxPhotoStore
    let cache: PhotoMapThumbnailCache
    let action: () -> Void

    @State private var image: UIImage?

    private static let side: CGFloat = 52

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    thumbnail
                        .frame(width: Self.side, height: Self.side)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white, lineWidth: 2))
                    if pin.count > 1 {
                        Text(pin.count > 999 ? "999+" : "\(pin.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                            .overlay(Capsule().stroke(.white, lineWidth: 1))
                            .offset(x: 6, y: 6)
                    }
                }
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .offset(y: -1)
            }
            .shadow(radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("\(pin.count) photos")))
        // ⚠️ `id:` は代表写真。畳み直しで代表が変わったときだけ取り直す（同じ写真なら再取得しない）。
        .task(id: pin.representative.identifier) {
            let key = pin.representative.identifier
            if let cached = await cache.image(for: key) { image = cached; return }
            let loaded = await loadCover(
                localID: pin.representative.isLocal ? key : nil,
                cloudPath: pin.representative.isLocal ? nil : key,
                dropboxStore: dropboxStore, maxPixel: Self.side * 3)
            guard !Task.isCancelled, let loaded else { return }
            await cache.store(loaded, for: key)
            image = loaded
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            // 取得中も**位置と件数は分かる**ようにしておく（真っ白のカードを出さない）。
            ZStack {
                Rectangle().fill(.regularMaterial)
                Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// 代表写真サムネのセッションキャッシュ（画面を閉じたら消える）。
/// actor にして、複数ピンの同時取得から守る。
actor PhotoMapThumbnailCache {
    private var images: [String: UIImage] = [:]
    /// ⚠️ 上限を置く。地図を動かし続けると代表写真は入れ替わり続けるので、
    /// 際限なく持つと画面を開いている間ずっとメモリが増える。
    private let limit = 200
    private var order: [String] = []

    func image(for key: String) -> UIImage? { images[key] }

    func store(_ image: UIImage, for key: String) {
        if images[key] == nil { order.append(key) }
        images[key] = image
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
        }
    }
}

/// ピン 1 つぶんの写真（＝そのグリッドセルの写真）。既存のグリッド/フル画面をそのまま使う
/// （`PlacePhotosView` と同型＝新しい表示コードを増やさない）。
private struct PhotoMapCellView: View {
    @State private var store: MergedPhotoStore
    private let title: String

    init(pin: PhotoMapPin, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex) {
        _store = State(initialValue: .forMembers(
            localIDs: pin.members.filter(\.isLocal).map(\.identifier),
            cloudPaths: pin.members.filter { !$0.isLocal }.map(\.identifier),
            dropboxStore: dropboxStore, assetIndex: assetIndex))
        title = String(localized: "\(pin.count) photos")
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: title)
    }
}
