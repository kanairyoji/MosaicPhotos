import LocalPhotoKit
import Photos
import UIKit
import XCTest

/// Layer 3: 実 PHImageManager 経路の統合テスト（フィクスチャ PHAsset）。
///
/// 合成した**縦長マーカー画像**を写真ライブラリへ一時保存し、`LocalPhotoStore` のサムネ取得を
/// 小サイズ・大サイズの両方で呼んで、四隅オラクルで**正立**を確認する。実機/写真ライブラリの
/// PHImageManager を実際に通す最も忠実な自動テスト。
///
/// ⚠️ 写真ライブラリへ書き込むため**既定ではスキップ**（環境変数 `RUN_PHOTO_FIXTURE_TESTS=1` で有効化）。
/// 実行時も追加した**テスト用アセットは必ず削除**する（ユーザーの写真は触らない）。CI/手動検証用。
final class PhotoFixtureOrientationTests: XCTestCase {

    private var createdLocalID: String?

    override func tearDown() async throws {
        if let id = createdLocalID { await Self.deleteAsset(id) ; createdLocalID = nil }
        try await super.tearDown()
    }

    @MainActor
    func testThumbnailsAreUprightThroughRealPipeline() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_PHOTO_FIXTURE_TESTS"] == "1",
                          "opt-in（写真ライブラリへ書き込むため）: RUN_PHOTO_FIXTURE_TESTS=1 で実行")
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        try XCTSkipUnless(status == .authorized, "写真ライブラリ readWrite 権限が必要")

        // 縦長マーカー（左上=赤/右上=緑/左下=青/右下=黄）を保存し localIdentifier を得る。
        let marker = OrientationOracle.markerImage(width: 800, height: 1200)
        let jpeg = try XCTUnwrap(marker.jpegData(compressionQuality: 0.95))
        let id = try await Self.createAsset(jpeg: jpeg)
        createdLocalID = id

        let store = LocalPhotoStore(localIdentifiers: [id])
        await store.start()
        let item = try XCTUnwrap(store.items.first, "テストアセットが LocalPhotoStore に載っていない")

        // 小サイズ（バグが出ていた域）と大サイズの両方で正立を確認する。
        for side in [CGFloat(200), CGFloat(1024)] {
            let raw = await store.thumbnail(for: item, targetSize: CGSize(width: side, height: side))
            let thumb = try XCTUnwrap(raw, "サムネ取得に失敗（side=\(side)）")
            XCTAssertEqual(OrientationOracle.cornerColors(thumb),
                           [.red, .green, .blue, .yellow],
                           "サムネが正立していない（side=\(side)）")
        }
    }

    // MARK: - 写真ライブラリ 追加/削除

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
