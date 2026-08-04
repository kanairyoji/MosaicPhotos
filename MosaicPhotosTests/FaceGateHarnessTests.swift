import ImageIO
import MobileCLIPKit
import XCTest

/// 顔ゲートの**検証ハーネス**（ADR-53）。端末に写真を入れて大量スキャンせずに、
/// 問題写真だけでゲート（検出信頼度・サイズ・ぼけ・露出・クロップ再検証）の挙動を確認する。
///
/// 使い方:
/// 1. `~/DEV/tmp/face-samples/` に問題写真（誤検出された写真・正しく認識してほしい写真）を置く
///    （別の場所なら環境変数 `TEST_RUNNER_FACE_SAMPLES_DIR` で指定）。
/// 2. 実行:
///    xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
///      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///      -only-testing:MosaicPhotosTests/FaceGateHarnessTests
/// 3. ログの `FACEGATE:` 行に 1 顔ずつの判定（通過/棄却理由・信頼度・品質・ぼけ・露出）が出る。
///    しきい値は `FaceQualityGate`（AutoAlbumCore/Faces/FaceSeams.swift）に集約されているので、
///    調整→再実行（数十秒）で回せる。
///
/// ⚠️ シミュレータでは Vision の品質・信頼度が実機と多少異なる（fallback 経路）。
///    数値の傾向確認・しきい値の当たり付けに使い、最終確認は実機で行う。
final class FaceGateHarnessTests: XCTestCase {

    func testAnalyzeSampleFolder() async throws {
        // シミュレータのホームはサンドボックス内なので、Mac のパスを直接指定する。
        let dir = ProcessInfo.processInfo.environment["FACE_SAMPLES_DIR"] ?? "/Users/kanai/DEV/tmp/face-samples"
        var isDirectory: ObjCBool = false
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
                          && isDirectory.boolValue,
                          "サンプルフォルダなし: \(dir)（問題写真を置いて再実行）")
        try XCTSkipUnless(FaceModel.modelBundled, "顔モデル未同梱（scripts/build_facenet.sh で生成）")

        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipUnless(!urls.isEmpty, "画像ファイルなし: \(dir)")

        let adapter = FacePerceptionAdapter()
        var totalFaces = 0
        var accepted = 0
        for url in urls {
            guard let cg = Self.loadCGImage(url, maxPixel: 1024) else {
                print("FACEGATE: \(url.lastPathComponent) — 読み込み失敗")
                continue
            }
            let reports = await adapter.debugAnalyze(cg)
            totalFaces += reports.count
            accepted += reports.filter(\.accepted).count
            print("FACEGATE: \(url.lastPathComponent) 検出=\(reports.count)")
            for (i, r) in reports.enumerated() {
                let blur = r.blurVariance.map { String(format: "%.0f", $0) } ?? "—"
                let luma = r.meanLuma.map { String(format: "%.0f", $0) } ?? "—"
                let verdict = r.accepted
                    ? (r.adjustedQuality < 0.40 ? "記録のみ(フロア未満)" : "採用")
                    : "棄却(\(r.rejectReason ?? "?"))"
                print(String(format: "FACEGATE:   #%d %@ conf=%.2f q=%.2f→%.2f blur=%@ luma=%@ %.0fx%.0fpx",
                             i, verdict, r.confidence, r.rawQuality, r.adjustedQuality,
                             blur, luma, r.pixelSize.width, r.pixelSize.height))
            }
        }
        print("FACEGATE: 合計 画像=\(urls.count) 検出顔=\(totalFaces) 採用=\(accepted)")
    }

    /// CGImageSource でダウンサンプルつきロード（本番の 1024px 処理と同条件）。
    private static func loadCGImage(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
