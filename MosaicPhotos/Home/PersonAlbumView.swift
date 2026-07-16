import AutoAlbumCore
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Person photo album (ローカル＋クラウドのメンバーを表示)

/// 人物（顔クラスタ）の写真アルバム。メンバー限定の MergedPhotoStore（ローカル ID 絞り込み＋
/// クラウド path 絞り込み）で、端末写真もクラウド写真も表示する（PlacePhotosView と同型）。
/// ※ 顔検出はクラウドを 128px サムネで行うため、クラウドメンバーは大きく写った顔中心（ADR: option B）。
struct PersonAlbumView: View {
    @State private var store: MergedPhotoStore
    private let title: String

    init(person: PersonInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex) {
        // 索引（起動時構築）があれば辞書引きで即構築、無ければ従来のフェッチにフォールバック。
        let memberIDs = localIdentifiers(from: person.memberRefKeys)
        let localStore = assetIndex.assets(for: memberIDs).map { LocalPhotoStore(preloadedAssets: $0) }
            ?? LocalPhotoStore(localIdentifiers: memberIDs)
        _store = State(initialValue: MergedPhotoStore(
            dropboxStore: dropboxStore,
            localStore: localStore,
            cloudPathFilter: Set(cloudPaths(from: person.memberRefKeys))
        ))
        title = person.displayName
    }

    var body: some View {
        PhotoSourceContentView(store: store, title: title)
    }
}
