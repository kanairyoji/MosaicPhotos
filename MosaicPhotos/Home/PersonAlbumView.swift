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
    private let person: PersonInfo
    private let peopleEngine: PeopleEngine

    init(person: PersonInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex,
         peopleEngine: PeopleEngine) {
        self.person = person
        self.peopleEngine = peopleEngine
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
            // 全画面表示で「この人物として認識した顔」を黄枠でハイライトする
            //（複数人の写真でどの顔か分かるように・ADR-46 追補）。
            .environment(\.faceHighlightProvider) { [peopleEngine, clusterID = person.clusterID] id in
                await peopleEngine.faceHighlights(forItemID: id, clusterID: clusterID)
            }
    }
}
