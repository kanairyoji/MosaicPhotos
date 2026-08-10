import AutoAlbumCore
import DropboxKit
import LocalPhotoKit
import Photos
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI
import UIKit

// MARK: - Person photo album (ローカル＋クラウドのメンバーを表示)

/// 人物（顔クラスタ）の写真アルバム。メンバー限定の MergedPhotoStore（ローカル ID 絞り込み＋
/// クラウド path 絞り込み）で、端末写真もクラウド写真も表示する（PlacePhotosView と同型）。
/// ※ 顔検出はクラウドを 128px サムネで行うため、クラウドメンバーは大きく写った顔中心（ADR: option B）。
struct PersonAlbumView: View {
    /// ⚠️ メンバーは**この画面が開いてから**取りに来る（`.task` で 1 回）。
    /// 以前は `person.memberRefKeys` を `init` で decode してストアを組み立てていたが、
    /// SwiftUI はビュー再評価のたびに `init` を呼ぶため、人物リストが再発行されるたびに
    /// 全メンバーキーの decode が MainActor で走っていた（ADR-95）。
    @State private var store: MergedPhotoStore?
    private let title: String
    private let person: PersonInfo
    private let dropboxStore: DropboxPhotoStore
    private let peopleEngine: PeopleEngine
    private let assetIndex: LocalAssetIndex
    /// 画面内「…」メニューの対象（設定すると人物メニュー＝改名/代表/顔管理/束ね が開く）。
    @State private var menuTarget: PersonInfo?

    init(person: PersonInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex,
         peopleEngine: PeopleEngine) {
        self.person = person
        self.dropboxStore = dropboxStore
        self.peopleEngine = peopleEngine
        self.assetIndex = assetIndex
        title = person.displayName
    }

    var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard store == nil else { return }
            let members = await peopleEngine.memberRefKeys(forPerson: person.clusterID)
            store = .forMembers(localIDs: localIdentifiers(from: members),
                                cloudPaths: cloudPaths(from: members),
                                dropboxStore: dropboxStore, assetIndex: assetIndex)
        }
    }

    private func content(store: MergedPhotoStore) -> some View {
        PhotoSourceContentView(store: store, title: title)
            // 全画面表示で「この人物として認識した顔」を黄枠でハイライトする
            //（複数人の写真でどの顔か分かるように・ADR-46 追補）。
            .environment(\.faceHighlightProvider) { [peopleEngine, clusterID = person.clusterID] id in
                await peopleEngine.faceHighlights(forItemID: id, clusterID: clusterID)
            }
            // サムネイルグリッド用（下部バーの「顔を表示」トグル）。グリッドは中央正方形
            // トリミング表示なので、元画像のアスペクト比で正方形クロップ座標へ変換して渡す。
            .environment(\.faceHighlightGridProvider) { id in
                await gridFaceRects(itemID: id)
            }
            // 画面内「…」→ ホームカードの長押しと同じ人物メニュー（改名/代表/顔管理/束ね）。
            .peopleActions(for: $menuTarget, engine: peopleEngine)
            .environment(\.sourceMenuContent) { [person] in
                AnyView(
                    Button { menuTarget = person } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(Text("Person options"))
                )
            }
    }

    /// グリッドセル用の顔矩形（正方形クロップの単位座標・原点左上）。
    private func gridFaceRects(itemID: String) async -> [CGRect] {
        let boxes = await peopleEngine.faceHighlights(forItemID: itemID, clusterID: person.clusterID)
        guard !boxes.isEmpty else { return [] }
        return FaceBoxMapping.squareCropUnitRects(visionBoxes: boxes,
                                                  aspectRatio: await originalAspect(itemID: itemID))
    }

    /// 元画像のアスペクト比（幅/高さ）。端末写真は PHAsset のピクセル寸法
    /// （グリッドのサムネは正方形トリミング済みのことがあり当てにならない）、
    /// クラウド写真はキャッシュ済みサムネ（Dropbox はアスペクト保持）から推定。不明は 1。
    private func originalAspect(itemID: String) async -> CGFloat {
        if itemID.hasPrefix("L-"),
           let asset = assetIndex.asset(for: String(itemID.dropFirst(2))),
           asset.pixelWidth > 0, asset.pixelHeight > 0 {
            return CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight)
        }
        if let store, let item = store.items.first(where: { $0.id == itemID }),
           let thumb = await store.thumbnail(for: item), thumb.size.height > 0 {
            return thumb.size.width / thumb.size.height
        }
        return 1
    }
}
