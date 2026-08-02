import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit

extension MergedPhotoStore {
    /// メンバー限定ストアの共通生成。ローカル ID は索引（`LocalAssetIndex`）から即解決し、
    /// 未構築なら `localIdentifiers` で遅延取得にフォールバック。クラウドは path フィルタ。
    /// PersonAlbum / AutoAlbumPhotos / DeviceAlbumPhotos / PlacePhotos の 4 ビューが同型の定型を
    /// 各 init に複写していたのを 1 箇所へ集約する。
    @MainActor
    static func forMembers(localIDs: [String], cloudPaths: [String],
                           dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex) -> MergedPhotoStore {
        let localStore = assetIndex.assets(for: localIDs).map { LocalPhotoStore(preloadedAssets: $0) }
            ?? LocalPhotoStore(localIdentifiers: localIDs)
        return MergedPhotoStore(dropboxStore: dropboxStore, localStore: localStore,
                                cloudPathFilter: Set(cloudPaths))
    }
}
