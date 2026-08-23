import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - 受信した共有アルバムのカルーセル（ホーム・ADR-112）

/// クラウド共有で**受け取った**アルバム（家族フォルダ配下の共有セット）を、
/// 他のアルバムセクションと同じ正方カードの横スクロールで表示する。
struct SharedAlbumsCarousel: View {
    let albums: [SharedAlbumDiscovery.Album]
    let dropboxStore: DropboxPhotoStore
    let onSelect: (SharedAlbumDiscovery.Album) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(albums) { album in
                    Button { onSelect(album) } label: {
                        LibraryCard(
                            title: album.name,
                            subtitle: String(format: L("%d photos"), album.photoCount),
                            placeholderSystemImage: "icloud.and.arrow.down",
                            coverKey: album.id
                        ) {
                            guard let cover = album.coverPath else { return nil }
                            return await loadCover(localID: nil, cloudPath: cover,
                                                   dropboxStore: dropboxStore,
                                                   maxPixel: LibraryCard.side * 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .id(album.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollTargetBehavior(.viewAligned)
        .listRowInsets(EdgeInsets())
    }
}

// MARK: - 受信アルバムの写真表示

/// 受け取った共有アルバム（＝家族フォルダ配下の 1 フォルダ）の写真一覧。
/// メンバーは開いた時点の同期済みアイテムから解決する（同期の進行に追従）。
struct SharedAlbumPhotosView: View {
    private let album: SharedAlbumDiscovery.Album
    private let dropboxStore: DropboxPhotoStore
    private let assetIndex: LocalAssetIndex

    @State private var store: MergedPhotoStore?

    init(album: SharedAlbumDiscovery.Album, dropboxStore: DropboxPhotoStore,
         assetIndex: LocalAssetIndex) {
        self.album = album
        self.dropboxStore = dropboxStore
        self.assetIndex = assetIndex
    }

    var body: some View {
        Group {
            if let store {
                PhotoSourceContentView(store: store, title: album.name)
            } else {
                Color.clear.busyOverlay(true, text: L("Loading photos…"))
            }
        }
        .task {
            guard store == nil else { return }
            let prefix = album.folderPath.lowercased() + "/"
            let items = dropboxStore.items
            let paths = await Task.detached(priority: .userInitiated) {
                items.compactMap { item -> String? in
                    item.path.lowercased().hasPrefix(prefix) ? item.path : nil
                }
            }.value
            store = .forMembers(localIDs: [], cloudPaths: paths,
                                dropboxStore: dropboxStore, assetIndex: assetIndex)
        }
    }
}
