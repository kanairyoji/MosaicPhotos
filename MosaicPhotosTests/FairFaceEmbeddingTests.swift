import AutoAlbumCore
import ImageIO
import MobileCLIPKit
import XCTest

/// **FairFace の顔を本番と同じ処理で埋め込む**（赤ちゃん判定の学習材料・ADR-219）。
///
/// FairFace（CC BY 4.0・年齢区分に「0〜2 歳」がある）から `scripts` の手順で選んだ画像を、
/// 本番と同一の経路（検出 → 品質ゲート → 5 点整列 → マルチクロップ平均）に通し、埋め込みを
/// `<root>/embeddings-<model>.json` に書き出す。学習と評価は Python 側で行う
/// （`docs/architecture-note/records/face-accuracy.md` の 2026-09-22 FairFace 節）。
///
/// 使い方:
///   xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///     -only-testing:MosaicPhotosTests/FairFaceEmbeddingTests
/// 途中で止まっても、次の実行は続きから進む（200 枚ごとに保存）。
final class FairFaceEmbeddingTests: XCTestCase {

    static let root = ProcessInfo.processInfo.environment["FAIRFACE_DIR"]
        ?? "/Users/kanai/DEV/tmp/face-eval-fairface"

    struct Entry: Codable {
        let embedding: [Float]?
        let quality: Float?
        let pixel: Double?
    }

    func testExtractEmbeddings() async throws {
        let labels = Self.root + "/labels.csv"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: labels), "FairFace なし")
        try XCTSkipUnless(FaceModel.modelBundled, "顔モデル未同梱")
        let model = Self.modelID
        let cachePath = Self.root + "/embeddings-\(model).json"
        var cache: [String: Entry] = [:]
        if let data = FileManager.default.contents(atPath: cachePath) {
            cache = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        let files = try String(contentsOfFile: labels, encoding: .utf8)
            .split(whereSeparator: \.isNewline).dropFirst()
            .compactMap { $0.split(separator: ",").first.map(String.init) }
        let adapter = FacePerceptionAdapter()
        var processed = 0
        for file in files where cache[file] == nil {
            let url = URL(fileURLWithPath: "\(Self.root)/images/\(file)")
            guard let cg = autoreleasepool(invoking: { Self.loadCGImage(url) }) else {
                cache[file] = Entry(embedding: nil, quality: nil, pixel: nil)
                continue
            }
            // いちばん大きく写った採用顔（FairFace は 1 枚 1 人の顔を中心に切り出してある）。
            let best = await adapter.debugAnalyzeWithEmbeddings(cg)
                .filter { $0.embedding != nil }
                .max { $0.report.pixelSize.width < $1.report.pixelSize.width }
            cache[file] = Entry(embedding: best?.embedding, quality: best?.quality,
                                pixel: best.map { Double($0.report.pixelSize.width) })
            processed += 1
            if processed % 200 == 0 {
                try JSONEncoder().encode(cache).write(to: URL(fileURLWithPath: cachePath))
                print("FAIRFACE: \(cache.count)/\(files.count)")
            }
        }
        try JSONEncoder().encode(cache).write(to: URL(fileURLWithPath: cachePath))
        let embedded = cache.values.filter { $0.embedding != nil }.count
        print("FAIRFACE: 完了 \(cache.count) 枚・埋め込み \(embedded)")
        XCTAssertGreaterThan(embedded, files.count / 2, "半分以上の画像で顔が取れていない")
    }

    static var modelID: String {
        guard let url = Bundle.main.url(forResource: "face_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String else { return "unknown" }
        return model
    }

    private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
