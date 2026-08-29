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

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                ForEach(pins) { pin in
                    Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                        PhotoMapPinBadge(count: pin.count) { selected = pin }
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
            .onDisappear {
                // 86k 件の索引を持ち帰らない（画面を閉じたら解放する）。
                loadTask?.cancel(); clusterTask?.cancel()
                candidates = []; pins = []
            }
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

    private func load() async {
        let task = Task { await placeScanner.locatedCandidates(dropboxItems: dropboxStore.items) }
        loadTask = task
        let found = await runShowingBusy($isLoading) { await task.value }
        loadTask = nil
        guard !task.isCancelled else { return }
        candidates = found
        // 初期表示は写真の分布に合わせる（外れ値 1 枚で世界地図にしない）。
        if let region = PhotoMapClustering.boundingRegion(of: found) {
            camera = .region(Self.mapRegion(region))
            recluster(region: region)
        }
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
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

/// ピン（件数バッジ）。⚠️ 代表写真のサムネはまだ出さない（Step 2）——クラウドのサムネ取得は
/// 閲覧中の取得と同じ回線を使うので、集約とキャンセルが効いていることを先に確かめる。
private struct PhotoMapPinBadge: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(count > 999 ? "999+" : "\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .offset(y: -2)
            }
            .shadow(radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L("\(count) photos")))
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
