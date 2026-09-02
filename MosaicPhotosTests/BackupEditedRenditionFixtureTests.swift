import Photos
import UIKit
import XCTest
@testable import BackupKit

/// Layer 3: 実写真ライブラリでの統合テスト（ADR-168）。
///
/// 「編集済みの写真をバックアップすると、**画面に見えているもの**が上がるか」を、実際の
/// `PHAssetResource` 経路で確かめる。フィクスチャに調整（adjustmentData ＋ レンダリング結果）を
/// 付け、`BackupAssetReader.read` の返すバイト列の見た目が、`PHImageManager` が返す表示画像と
/// 一致することを見る。旧実装は `.photo`（原画）を優先していたため、ここで**編集前の姿**が返り、
/// オフロード（実削除）で編集結果が失われていた。
///
/// ⚠️ 写真ライブラリへ書き込むため**既定ではスキップ**（`RUN_PHOTO_FIXTURE_TESTS=1` で有効化）。
/// 実行時も追加したテスト用アセットは必ず削除する（ユーザーの写真は触らない）。
final class BackupEditedRenditionFixtureTests: XCTestCase {

    private var createdLocalID: String?

    override func tearDown() async throws {
        if let id = createdLocalID { await Self.deleteAsset(id); createdLocalID = nil }
        try await super.tearDown()
    }

    @MainActor
    func testReadReturnsTheEditedRenditionThatTheUserSees() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_PHOTO_FIXTURE_TESTS"] == "1",
                          "opt-in（写真ライブラリへ書き込むため）: RUN_PHOTO_FIXTURE_TESTS=1 で実行")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try XCTSkipUnless(status == .authorized, "写真ライブラリ readWrite 権限が必要")

        // 原画（赤/緑/青/黄）を保存 → 別配色（青/黄/赤/緑）を「編集結果」として適用する。
        let originalJPEG = try XCTUnwrap(
            OrientationOracle.markerImage(width: 600, height: 600).jpegData(compressionQuality: 0.95))
        let id = try await Self.createAsset(jpeg: originalJPEG)
        createdLocalID = id

        let editedJPEG = try XCTUnwrap(Self.swappedMarker(side: 600).jpegData(compressionQuality: 0.95))
        let expected: [OrientationOracle.Corner] = [.blue, .yellow, .red, .green]
        XCTAssertEqual(OrientationOracle.cornerColors(UIImage(data: editedJPEG)!), expected,
                       "fixture: 編集結果の配色が想定と違う")
        try await Self.applyEdit(localID: id, renderedJPEG: editedJPEG)

        let asset = try XCTUnwrap(
            PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
        XCTAssertTrue(PHAssetResource.assetResources(for: asset).contains { $0.type == .fullSizePhoto },
                      "fixture: 編集レンディションが作られていない")

        // バックアップが上げるバイト列＝「今の見た目」であること。
        guard case .success(let data, let filename, let isEdited) =
                await BackupAssetReader.read(asset: asset, fallback: "fallback.jpg") else {
            return XCTFail("編集済みフィクスチャの読み取りに失敗した")
        }
        XCTAssertTrue(isEdited, "編集結果ではなく原画を読んでいる")
        XCTAssertEqual(OrientationOracle.cornerColors(try XCTUnwrap(UIImage(data: data))), expected,
                       "バックアップされるのが編集前の姿になっている（オフロードで編集が失われる）")
        XCTAssertTrue(filename.contains("-edited."), "編集結果に専用の名前が付いていない: \(filename)")

        // 写真アプリの表示（PHImageManager）とも一致すること。
        let displayed = try await Self.displayImage(for: asset)
        XCTAssertEqual(OrientationOracle.cornerColors(displayed), expected,
                       "fixture: 表示画像が編集結果になっていない")
    }

    // MARK: - フィクスチャ

    /// 原画とは別配色のマーカー（左上=青/右上=黄/左下=赤/右下=緑）。
    private static func swappedMarker(side: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt).image { ctx in
            let c = ctx.cgContext
            let h = side / 2
            c.setFillColor(UIColor.blue.cgColor);   c.fill(CGRect(x: 0, y: 0, width: h, height: h))
            c.setFillColor(UIColor.yellow.cgColor); c.fill(CGRect(x: h, y: 0, width: h, height: h))
            c.setFillColor(UIColor.red.cgColor);    c.fill(CGRect(x: 0, y: h, width: h, height: h))
            c.setFillColor(UIColor.green.cgColor);  c.fill(CGRect(x: h, y: h, width: h, height: h))
        }
    }

    private static func createAsset(jpeg: Data) async throws -> String {
        var placeholderID: String?
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: jpeg, options: nil)
                placeholderID = req.placeholderForCreatedAsset?.localIdentifier
            }, completionHandler: { ok, err in
                if let err { cont.resume(throwing: err) } else if !ok {
                    cont.resume(throwing: NSError(domain: "fixture", code: 1))
                } else { cont.resume(returning: ()) }
            })
        }
        return try XCTUnwrap(placeholderID)
    }

    /// 調整（adjustmentData）とレンダリング結果を書き込んで「編集済み」にする。
    private static func applyEdit(localID: String, renderedJPEG: Data) async throws {
        let asset = try XCTUnwrap(
            PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject)
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { cont in
            asset.requestContentEditingInput(with: PHContentEditingInputRequestOptions()) { input, _ in
                if let input { cont.resume(returning: input) }
                else { cont.resume(throwing: NSError(domain: "fixture", code: 2)) }
            }
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "org.r89.MosaicPhotos.test", formatVersion: "1",
            data: Data("marker-swap".utf8))
        try renderedJPEG.write(to: output.renderedContentURL)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let req = PHAssetChangeRequest(for: asset)
                req.contentEditingOutput = output
            }, completionHandler: { ok, err in
                if let err { cont.resume(throwing: err) } else if !ok {
                    cont.resume(throwing: NSError(domain: "fixture", code: 3))
                } else { cont.resume(returning: ()) }
            })
        }
    }

    private static func displayImage(for asset: PHAsset) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 600, height: 600),
                contentMode: .aspectFit, options: options) { image, _ in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: NSError(domain: "fixture", code: 4)) }
            }
        }
    }

    private static func deleteAsset(_ localID: String) async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil)
        guard assets.count > 0 else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assets)
            }, completionHandler: { _, _ in cont.resume(returning: ()) })
        }
    }
}
