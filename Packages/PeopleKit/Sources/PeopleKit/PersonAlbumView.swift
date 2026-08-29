#if canImport(UIKit)
import AutoAlbumCore
import MosaicSupport
import DropboxKit
import LocalPhotoKit
import Photos
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI
import UIKit

// MARK: - Person photo album (ローカル＋クラウドのメンバーを表示)

/// `sheet(item:)` 用の写真 ID ラッパ（String をそのまま Identifiable にはできないため）。
private struct PhotoIdentifier: Identifiable, Equatable {
    let id: String
}

/// 人物（顔クラスタ）の写真アルバム。メンバー限定の MergedPhotoStore（ローカル ID 絞り込み＋
/// クラウド path 絞り込み）で、端末写真もクラウド写真も表示する（PlacePhotosView と同型）。
/// ※ 顔検出はクラウドを 128px サムネで行うため、クラウドメンバーは大きく写った顔中心（ADR: option B）。
public struct PersonAlbumView: View {
    /// ⚠️ メンバーは**この画面が開いてから**取りに来る（`.task` で 1 回）。
    /// 以前は `person.memberRefKeys` を `init` で decode してストアを組み立てていたが、
    /// SwiftUI はビュー再評価のたびに `init` を呼ぶため、人物リストが再発行されるたびに
    /// 全メンバーキーの decode が MainActor で走っていた（ADR-95）。
    @State private var store: MergedPhotoStore?
    /// 表示中の人物。束ねると**主クラスタが相手側に移る**ことがあるので、操作のたびに引き直す
    /// （タイトル＝名前もここから出す）。
    @State private var current: PersonInfo
    /// いま store を組んだメンバー（refKey）。変化が無ければ組み直さない
    /// ——組み直すとスクロール位置が先頭に戻るため、必要なときだけにする。
    @State private var members: [String] = []
    private let dropboxStore: DropboxPhotoStore
    private let peopleEngine: PeopleEngine
    private let assetIndex: LocalAssetIndex
    /// 画面内「…」メニューの対象（設定すると人物メニュー＝改名/代表/顔管理/束ね が開く）。
    @State private var menuTarget: PersonInfo?
    /// 「この写真は別の人」で付け替え先を選ぶ対象の写真（表示側 ID）。
    @State private var reassignItemID: PhotoIdentifier?

    public init(person: PersonInfo, dropboxStore: DropboxPhotoStore, assetIndex: LocalAssetIndex,
         peopleEngine: PeopleEngine) {
        self.dropboxStore = dropboxStore
        self.peopleEngine = peopleEngine
        self.assetIndex = assetIndex
        _current = State(initialValue: person)
    }

    public var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                // メンバー取得中（写真の多い人物ほど待つ）。メインが止まっても回り続ける表示にする。
                Color.clear.busyOverlay(true, text: L("Loading photos…"))
            }
        }
        .task {
            guard store == nil else { return }
            await reload()
        }
    }

    /// 人物とメンバーを取り直して、変わっていれば写真ストアを組み直す。
    /// 「この写真はこの人ではない」「別の人と束ねる」「顔の管理」の直後に呼ぶ
    /// ——**開いたままのアルバムが古い内容を映し続けない**ようにする（実フィードバック）。
    private func reload() async {
        // 束ねたあとは主クラスタが相手側に移り得る。移った先の人物として描き直す
        // ＝「束ねた先のアルバム」がそのまま出る（メンバーは束ね全体で解決される）。
        let target = await peopleEngine.person(containing: current.clusterID) ?? current
        let latest = await peopleEngine.memberRefKeys(forPerson: target.clusterID)
        current = target
        guard store == nil || latest != members else { return }
        members = latest
        store = .forMembers(localIDs: localIdentifiers(from: latest),
                            cloudPaths: cloudPaths(from: latest),
                            dropboxStore: dropboxStore, assetIndex: assetIndex)
    }

    private func content(store: MergedPhotoStore) -> some View {
        PhotoSourceContentView(store: store, title: current.displayName)
            // 全画面表示で「この人物として認識した顔」を黄枠でハイライトする
            //（複数人の写真でどの顔か分かるように・ADR-46 追補）。
            .environment(\.faceHighlightProvider) { [peopleEngine, clusterID = current.clusterID] id in
                await peopleEngine.faceHighlights(forItemID: id, clusterID: clusterID)
            }
            // サムネイルグリッド用（下部バーの「顔を表示」トグル）。グリッドは中央正方形
            // トリミング表示なので、元画像のアスペクト比で正方形クロップ座標へ変換して渡す。
            .environment(\.faceHighlightGridProvider) { id in
                await gridFaceRects(itemID: id)
            }
            // ⚠️ サムネイル長押し・全画面メニューから「この写真はこの人ではない」を直接呼べる
            // （実フィードバック: **全体像や前後関係で違うと気づく**ことがある。顔だけを並べた
            // 「顔の管理」ではその気づき方ができない）。ADR-45 の負例として学習され、
            // 再スキャン・再クラスタでも同じ誤りは再発しない。
            .environment(\.photoContextActions, [
                PhotoContextAction(
                    id: "not-this-person",
                    title: L("Not “\(current.displayName)”"),
                    systemImage: "person.crop.circle.badge.xmark",
                    isDestructive: true
                ) { itemID in
                    let clusterID = current.clusterID
                    let removed = await peopleEngine.removePhoto(itemID: itemID, from: clusterID)
                    Diagnostics.mark("people: removed \(removed) face(s) from cluster \(clusterID)")
                    // その場でアルバムを描き直す（外した写真が残って見えない）。取り消しは
                    // 「顔の管理」から別の人物へ付け替えることでできる。
                    await reload()
                },
                // 相手が分かっているときは**選んで移す**。外すだけより情報量が多く、
                // 付け替え先の確認顔（アンカー）として学習される（ADR-46）。
                PhotoContextAction(
                    id: "someone-else",
                    title: L("Someone Else…"),
                    systemImage: "person.2.crop.square.stack"
                ) { itemID in
                    reassignItemID = PhotoIdentifier(id: itemID)
                }
            ])
            // ⚠️ ここは**この人物のアルバム**なので、写真ごとの動的な操作（1 人だけ写っている
            // 写真に出る汎用の人物修正）は出さない——同じ項目が 2 つ並ぶため。
            .environment(\.photoContextActionProvider, nil)
            // 付け替え先の人物ピッカー（グリッド長押し・全画面メニューのどちらからでも開く）。
            .sheet(item: $reassignItemID) { target in
                PhotoPersonPickerView(itemID: target.id, currentClusterID: current.clusterID,
                                      peopleEngine: peopleEngine) { toClusterID in
                    Task {
                        let moved = await peopleEngine.movePhoto(itemID: target.id,
                                                                 from: current.clusterID,
                                                                 to: toClusterID)
                        Diagnostics.mark("people: moved \(moved) face(s) \(current.clusterID)→"
                                         + (toClusterID.map(String.init) ?? "new"))
                        await reload()
                    }
                }
            }
            // 画面内「…」→ ホームカードの長押しと同じ人物メニュー（改名/代表/顔管理/束ね）。
            // 束ね・改名・顔の管理などが終わったら、この画面も追随して描き直す。
            .peopleActions(for: $menuTarget, engine: peopleEngine,
                           onChanged: { Task { await reload() } })
            .environment(\.sourceMenuContent) {
                AnyView(
                    Button { menuTarget = current } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel(Text("Person options"))
                )
            }
    }

    /// グリッドセル用の顔矩形（正方形クロップの単位座標・原点左上）。
    private func gridFaceRects(itemID: String) async -> [CGRect] {
        let boxes = await peopleEngine.faceHighlights(forItemID: itemID, clusterID: current.clusterID)
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
#endif
