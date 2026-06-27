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
    private let needsSetup = PhotoLoadState.needsSetup(message: "m", detail: nil, systemImage: "x")

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
        let date = Date(timeIntervalSince1970: 1000)
        let withLoc = cloud("/a.jpg", lat: 35.5, lon: 139.5, date: date)
        #expect(withLoc.captureDate == date)
        #expect(withLoc.coordinate?.latitude == 35.5)
        #expect(withLoc.coordinate?.longitude == 139.5)

        let noLoc = cloud("/b.jpg")
        #expect(noLoc.coordinate == nil)
        #expect(noLoc.captureDate == nil)
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

@Suite("placeScanSignature")
struct PlaceScanSignatureTests {
    private func located(_ path: String) -> DropboxFileItem {
        DropboxFileItem(path: path, name: "n", latitude: 35.0, longitude: 139.0)
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
