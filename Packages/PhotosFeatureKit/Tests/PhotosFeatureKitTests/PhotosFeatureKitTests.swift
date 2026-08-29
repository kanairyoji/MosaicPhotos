//
//  PhotosFeatureKitTests.swift
//  PhotosFeatureKit
//
//  統合ストアのフィルタ/状態解決、統合アイテムの ID、場所スキャンの署名を Swift Testing で検証する。
//  対象型は UIKit 依存のため iOS シミュレータでのみ実行する。
//

#if canImport(UIKit)
import CoreLocation
import DropboxKit
import Foundation
import PhotoSourceKit
import Testing
@testable import PhotosFeatureKit

// MARK: - MergedPhotoStore pure helpers

@Suite("MergedPhotoStore.filteredCloudItems")
struct FilteredCloudItemsTests {
    private func item(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: (path as NSString).lastPathComponent)
    }

    @Test("フィルタが nil なら全件返す")
    func nilFilterReturnsAll() {
        let items = [item("/a.jpg"), item("/b.jpg")]
        #expect(MergedPhotoStore.filteredCloudItems(items, filter: nil).map(\.path) == ["/a.jpg", "/b.jpg"])
    }

    @Test("フィルタに含まれるパスだけ返す（順序は元のまま）")
    func keepsOnlyFiltered() {
        let items = [item("/a.jpg"), item("/b.jpg"), item("/c.jpg")]
        let result = MergedPhotoStore.filteredCloudItems(items, filter: ["/a.jpg", "/c.jpg"])
        #expect(result.map(\.path) == ["/a.jpg", "/c.jpg"])
    }

    @Test("空フィルタは空を返す")
    func emptyFilterReturnsEmpty() {
        #expect(MergedPhotoStore.filteredCloudItems([item("/a.jpg")], filter: []).isEmpty)
    }
}

@Suite("MergedPhotoStore.resolveState")
struct ResolveStateTests {
    private let needsSetup = PhotoLoadState.needsSetup(message: "m", detail: nil, systemImage: "x", action: nil)

    @Test("ローカルが needsSetup なら全体をブロック（Dropbox があっても）")
    func needsSetupBlocks() {
        let s = MergedPhotoStore.resolveState(localState: needsSetup, hasLocalAssets: false, hasDropbox: true)
        #expect(s == needsSetup)
    }

    @Test("ローカルが failed ならそのまま failed")
    func failedPassesThrough() {
        let s = MergedPhotoStore.resolveState(localState: .failed("boom"), hasLocalAssets: false, hasDropbox: true)
        #expect(s == .failed("boom"))
    }

    @Test("いずれかにアイテムがあれば loaded")
    func anyItemsLoaded() {
        #expect(MergedPhotoStore.resolveState(localState: .loaded, hasLocalAssets: true, hasDropbox: false) == .loaded)
        #expect(MergedPhotoStore.resolveState(localState: .idle, hasLocalAssets: false, hasDropbox: true) == .loaded)
    }

    @Test("アイテム無し時はローカルの読み込み状況に従う")
    func emptyFollowsLocalState() {
        #expect(MergedPhotoStore.resolveState(localState: .idle, hasLocalAssets: false, hasDropbox: false) == .idle)
        #expect(MergedPhotoStore.resolveState(localState: .loading, hasLocalAssets: false, hasDropbox: false) == .loading)
        // loaded/empty などローカルが「完了」状態でアイテム無し → empty。
        #expect(MergedPhotoStore.resolveState(localState: .loaded, hasLocalAssets: false, hasDropbox: false) == .empty)
        #expect(MergedPhotoStore.resolveState(localState: .empty, hasLocalAssets: false, hasDropbox: false) == .empty)
    }

    @Test("T2: アイテム無しでも Dropbox 取得中なら empty ではなく loading")
    func dropboxBusyKeepsLoading() {
        // ローカル完了・アイテム無し・Dropbox 取得中 → "No photos" を出さず loading を維持。
        #expect(MergedPhotoStore.resolveState(
            localState: .loaded, hasLocalAssets: false, hasDropbox: false, dropboxBusy: true) == .loading)
        #expect(MergedPhotoStore.resolveState(
            localState: .empty, hasLocalAssets: false, hasDropbox: false, dropboxBusy: true) == .loading)
        // 取得完了（dropboxBusy=false）かつアイテム無し → empty。
        #expect(MergedPhotoStore.resolveState(
            localState: .loaded, hasLocalAssets: false, hasDropbox: false, dropboxBusy: false) == .empty)
        // dropboxBusy でもアイテムがあれば loaded が優先。
        #expect(MergedPhotoStore.resolveState(
            localState: .loaded, hasLocalAssets: false, hasDropbox: true, dropboxBusy: true) == .loaded)
    }
}

// MARK: - MergedPhotoItem

@Suite("MergedPhotoItem")
struct MergedPhotoItemTests {
    private func cloud(_ path: String, lat: Double? = nil, lon: Double? = nil, date: Date? = nil) -> MergedPhotoItem {
        .cloud(DropboxFileItem(path: path, name: (path as NSString).lastPathComponent,
                               captureDate: date, latitude: lat, longitude: lon))
    }

    @Test("cloud の id は \"C-\" プレフィックス付き（ローカルの \"L-\" と衝突しない）")
    func cloudIDPrefixed() {
        #expect(cloud("/trip/a.jpg").id == "C-/trip/a.jpg")
    }

    @Test("captureDate / coordinate は内包する要素へ委譲する")
    func delegatesAccessors() {
        // 有効窓（1990〜）内の日付を使う。無意味な日付は DropboxFileItem.init が nil に落とす（ADR-22）。
        let date = Date(timeIntervalSince1970: 1_577_836_800)   // 2020-01-01
        let withLoc = cloud("/a.jpg", lat: 35.5, lon: 139.5, date: date)
        #expect(withLoc.captureDate == date)
        #expect(withLoc.coordinate?.latitude == 35.5)
        #expect(withLoc.coordinate?.longitude == 139.5)

        let noLoc = cloud("/b.jpg")
        #expect(noLoc.coordinate == nil)
        #expect(noLoc.captureDate == nil)
    }

    @Test("無意味な撮影日時（1970 等）は入口で日時不明に落ちる")
    func bogusCaptureDateSanitizedAtIngress() {
        // ADR-22: DropboxFileItem.init がサニタイズするため、1970 の既定値は nil＝日時不明になる。
        let bogus = cloud("/c.jpg", date: Date(timeIntervalSince1970: 1000))
        #expect(bogus.captureDate == nil)
    }

    /// 回帰: クラウド写真のお気に入り（ADR-67 でアプリ側管理になった）を統合ビューでも扱えること。
    /// 以前は `isFavorite`/`supportsFavorite` が cloud を常に false にしており、All Photos だけ
    /// ハートが出ず付け外しもできなかった（`DropboxPhotoStore` 側は対応済みだったのに未追随）。
    @Test("クラウド写真のお気に入りを委譲する（常に false にしない）")
    func cloudFavoriteIsDelegated() {
        let plain = DropboxFileItem(path: "/a.jpg", name: "a.jpg")
        #expect(MergedPhotoItem.cloud(plain).isFavorite == false)
        #expect(MergedPhotoItem.cloud(plain).supportsFavorite)      // 付け外しは可能

        let faved = plain.withFavorite(true)
        #expect(MergedPhotoItem.cloud(faved).isFavorite)            // 刻印済みなら true
    }

    @Test("等価性・ハッシュは id 基準")
    func equalityByID() {
        #expect(cloud("/a.jpg") == cloud("/a.jpg"))
        #expect(cloud("/a.jpg") != cloud("/b.jpg"))
        let set: Set<MergedPhotoItem> = [cloud("/a.jpg"), cloud("/a.jpg"), cloud("/b.jpg")]
        #expect(set.count == 2)
    }
}

// MARK: - PlaceScanner signature

/// ⚠️ 再構築は `Task.detached` で走るため、**逆順で完了し得る**。`Task.isCancelled` の確認と
/// 代入の間にキャンセルされる競合は確認だけでは防げず、新しい結果を古いスナップショットが
/// 上書きし得る（レビュー指摘）。世代を照合して最新だけを通すこと。
@Suite("MergedPhotoStore rebuild generation")
@MainActor
struct MergedPhotoStoreGenerationTests {

    private func makeStore() -> MergedPhotoStore {
        MergedPhotoStore(dropboxStore: DropboxPhotoStore(
            auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb")))
    }

    private func item(_ path: String) -> MergedPhotoItem {
        .cloud(DropboxFileItem(path: path, name: (path as NSString).lastPathComponent))
    }

    @Test("遅れて届いた古い世代の結果は捨てる")
    func staleGenerationIsDropped() {
        let store = makeStore()
        let old = store.nextRebuildGenerationForTesting()
        let new = store.nextRebuildGenerationForTesting()

        store.setItems([item("/new.jpg")], generation: new, signature: 1)  // 新しい再構築が先に着いた
        store.setItems([item("/old.jpg")], generation: old, signature: 2)  // 古い再構築が遅れて到着

        #expect(store.items.map(\.id) == [item("/new.jpg").id],
                "追い越された古い一覧で上書きされた")
    }

    @Test("最新世代の結果は反映される")
    func currentGenerationIsApplied() {
        let store = makeStore()
        let generation = store.nextRebuildGenerationForTesting()
        store.setItems([item("/a.jpg")], generation: generation, signature: 1)
        #expect(store.items.count == 1)
    }

    /// ⚠️ 同期中は 0.4 秒ごとに再構築が走るが内容は変わらないことがほとんど。代入すると
    /// 配列の実体が変わり、グリッドが 86,000 件ぶんの ID 指紋をメインで取り直す。
    @Test("同じ指紋なら差し替えない")
    func sameSignatureKeepsArray() {
        let store = makeStore()
        store.setItems([item("/a.jpg")], generation: store.nextRebuildGenerationForTesting(),
                       signature: 42)
        let before = store.items
        store.setItems([item("/b.jpg")], generation: store.nextRebuildGenerationForTesting(),
                       signature: 42)
        #expect(store.items.map(\.id) == before.map(\.id), "同じ指紋なのに差し替えた")
    }

    @Test("指紋が変われば差し替える")
    func changedSignatureApplies() {
        let store = makeStore()
        store.setItems([item("/a.jpg")], generation: store.nextRebuildGenerationForTesting(),
                       signature: 1)
        store.setItems([item("/b.jpg")], generation: store.nextRebuildGenerationForTesting(),
                       signature: 2)
        #expect(store.items.map(\.id) == [item("/b.jpg").id], "変化を取りこぼした")
    }
}

@Suite("placeScanSignature")
struct PlaceScanSignatureTests {
    private func located(_ path: String, lat: Double = 35.0,
                         lon: Double = 139.0) -> DropboxFileItem {
        DropboxFileItem(path: path, name: "n", latitude: lat, longitude: lon)
    }
    private func unlocated(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: "n")
    }

    @Test("空・座標なしのみ → 署名 0")
    func emptyOrUnlocatedIsZero() {
        #expect(placeScanSignature([]) == 0)
        #expect(placeScanSignature([unlocated("/a.jpg"), unlocated("/b.jpg")]) == 0)
    }

    @Test("座標付きアイテムが増えると署名が変わる")
    func addingLocatedChangesSignature() {
        let before = placeScanSignature([located("/a.jpg")])
        let after = placeScanSignature([located("/a.jpg"), located("/b.jpg")])
        #expect(before != after)
    }

    @Test("座標が外れると署名が変わる")
    func removingCoordinateChangesSignature() {
        let withLoc = placeScanSignature([located("/a.jpg")])
        let without = placeScanSignature([unlocated("/a.jpg")])
        #expect(withLoc != without)
    }

    /// ⚠️ 同じパスのまま座標が変わる（写真の差し替え・位置情報の修正）ケース。
    /// 署名が変わらないと再スキャンが走らず、**古い市区町村に表示され続ける**（レビュー指摘）。
    @Test("同じパスでも座標が変われば署名が変わる")
    func movingCoordinateChangesSignature() {
        let tokyo = placeScanSignature([located("/a.jpg", lat: 35.68, lon: 139.76)])
        let osaka = placeScanSignature([located("/a.jpg", lat: 34.69, lon: 135.50)])
        #expect(tokyo != osaka, "同じパスで座標だけ変わった差分を取りこぼす")
    }

    /// 逆に、浮動小数の下位桁のゆらぎで再スキャンしない（約 1m に丸めて比較する）。
    @Test("1m 未満の誤差では署名が変わらない")
    func negligibleJitterKeepsSignature() {
        let a = placeScanSignature([located("/a.jpg", lat: 35.680000, lon: 139.760000)])
        let b = placeScanSignature([located("/a.jpg", lat: 35.6800000001, lon: 139.7600000001)])
        #expect(a == b, "誤差レベルの差で毎回再スキャンしてしまう")
    }

    @Test("並び順には依存しない（XOR）")
    func orderIndependent() {
        let ab = placeScanSignature([located("/a.jpg"), located("/b.jpg")])
        let ba = placeScanSignature([located("/b.jpg"), located("/a.jpg")])
        #expect(ab == ba)
    }

    @Test("座標なしアイテムの増減は署名に影響しない")
    func unlocatedDoesNotAffect() {
        let base = placeScanSignature([located("/a.jpg")])
        let withExtra = placeScanSignature([located("/a.jpg"), unlocated("/z.txt")])
        #expect(base == withExtra)
    }
}

// MARK: - EXIF GPS parsing

import ImageIO

@Suite("parseGPSCoordinate")
struct ParseGPSCoordinateTests {
    @Test("N/E は正、S/W は負に変換する")
    func signByRef() {
        let ne = parseGPSCoordinate([
            kCGImagePropertyGPSLatitude: 35.5, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.5, kCGImagePropertyGPSLongitudeRef: "E",
        ])
        #expect(ne.lat == 35.5)
        #expect(ne.lon == 139.5)

        let sw = parseGPSCoordinate([
            kCGImagePropertyGPSLatitude: 33.8, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2, kCGImagePropertyGPSLongitudeRef: "W",
        ])
        #expect(sw.lat == -33.8)
        #expect(sw.lon == -151.2)
    }

    @Test("緯度経度が欠ける辞書は lat/lon ともに nil")
    func missingValues() {
        let gps = parseGPSCoordinate([kCGImagePropertyGPSLatitudeRef: "N"])
        #expect(gps.lat == nil)
        #expect(gps.lon == nil)
    }
}
#endif

/// メンバー限定ストア（人物・グループ・場所・アルバム）でも**バックアップ副本を隠す**（ADR-128）。
///
/// ⚠️ 実フィードバック「グループアルバムが時系列で並んでいない／バックアップを新しい写真と
/// 認識している？」の原因。ホームの一覧には索引を渡していたが、`forMembers` で作るストアには
/// 渡していなかった。副本は端末の原本と**同じ写真**なので二重に並び、しかも副本の撮影日は
/// Dropbox に `time_taken` が無いと**アップロード時刻**に落ちる＝古い写真が「最新」の位置に出る。
@Suite("メンバー限定ストアの副本隠し")
@MainActor
struct MemberStoreBackupHidingTests {

    @Test("既定のプロバイダがメンバー限定ストアへ渡る")
    func defaultProviderIsWired() {
        let previous = MergedPhotoStore.defaultBackupCopyIndexProvider
        defer { MergedPhotoStore.defaultBackupCopyIndexProvider = previous }
        MergedPhotoStore.defaultBackupCopyIndexProvider = { ["/backup/a.jpg": "local-a"] }

        let store = MergedPhotoStore.forMembers(
            localIDs: ["local-a"], cloudPaths: ["/backup/a.jpg"],
            dropboxStore: DropboxPhotoStore(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb")),
            assetIndex: LocalAssetIndex())
        #expect(store.backupCopyIndexProvider != nil,
                "索引が渡っていない（アルバム画面で副本が二重に出て並びが壊れる）")
    }

    /// 隠す条件そのもの（純ロジック）。原本が**このアルバムに居るときだけ**隠す——
    /// オフロード済み（端末に原本が無い）写真まで隠すと、アルバムから写真が消える。
    @Test("原本が同じアルバムに居る副本だけを隠す")
    func hidesOnlyWhenOriginalIsPresent() {
        let index = ["/backup/a.jpg": "local-a", "/backup/b.jpg": "local-b"]
        let hidden = BackupCopyHiding.hiddenPaths(backupPathToLocalID: index,
                                                  localIdentifiers: ["local-a"])
        #expect(hidden == ["/backup/a.jpg"])
        #expect(!hidden.contains("/backup/b.jpg"), "原本が無い写真まで隠すと、アルバムから消える")
    }
}
