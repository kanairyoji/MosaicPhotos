import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Place photos view

/// 場所アルバムを開くビュー。メンバー限定の MergedPhotoStore（ローカル ID 絞り込み＋
/// Dropbox パスフィルタ）でローカル・Dropbox 混在のグリッドを表示する。
struct PlacePhotosView: View {
    @State private var store: MergedPhotoStore
    private let title: String

    init(place: PlaceAlbumInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex) {
        _store = State(initialValue: .forMembers(
            localIDs: place.localIDs, cloudPaths: place.cloudPaths,
            dropboxStore: dropboxStore, assetIndex: assetIndex))
        title = place.placeName
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: title)
    }
}
