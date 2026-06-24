import AutoAlbumCore
import UIKit
import XCTest
@testable import MosaicPhotos

/// オンデバイス画像認識（語彙ゼロのオープン語彙 CLIP 検索）の単体テスト。
///
/// 実写の代わりに**絵文字を大きく描いた画像**を決定的に生成して検証する。
/// CLIP モデルが未同梱の環境ではスキップする。
final class ImageRecognitionTests: XCTestCase {

    /// 絵文字をフレーム一杯に描いた正方形画像を作る。
    private func image(emoji: String, size: CGFloat = 512) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let uiImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let font = UIFont.systemFont(ofSize: size * 1.2)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            let str = emoji as NSString
            let textSize = str.size(withAttributes: attrs)
            str.draw(in: CGRect(x: (size - textSize.width) / 2,
                                y: (size - textSize.height) / 2,
                                width: textSize.width, height: textSize.height),
                     withAttributes: attrs)
        }
        return uiImage.cgImage!
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = na.squareRoot() * nb.squareRoot()
        return d == 0 ? 0 : dot / d
    }

    // MARK: - CLIP 健全性（NaN 回帰・モダリティ別）

    /// CLIP の画像・テキスト埋め込みが有限値（NaN/Inf でない）であることを検証する回帰テスト。
    /// fp16 変換だと画像タワーがシミュレータで全 NaN になる不具合を捕捉する。
    func testCLIPEmbeddingsAreFinite() throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "MobileCLIP models not bundled — skipping")
        let probe = image(emoji: "🐱")
        let image = try XCTUnwrap(MobileCLIPRuntime.shared.encodeImage(probe),
                                  "image embedding is nil (NaN/Inf? fp16 overflow on simulator)")
        let tokens = try XCTUnwrap(CLIPTokenizer.shared).encode("a photo of a cat")
        let text = try XCTUnwrap(MobileCLIPRuntime.shared.encodeText(tokens), "text embedding is nil")
        XCTAssertEqual(image.count, 512)
        XCTAssertEqual(text.count, 512)
        XCTAssertTrue(image.allSatisfy { $0.isFinite }, "image embedding contains NaN/Inf")
        XCTAssertTrue(text.allSatisfy { $0.isFinite }, "text embedding contains NaN/Inf")
    }

    /// 画像どうしの類似度で画像タワー単独の健全性を確認する（同種＞異種）。
    func testImageEmbeddingsDiscriminate() throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "models not bundled")
        func emb(_ e: String) throws -> [Float] {
            try XCTUnwrap(MobileCLIPRuntime.shared.encodeImage(image(emoji: e)))
        }
        let cat1 = try emb("🐱"), cat2 = try emb("🐈"), dog = try emb("🐶"), pizza = try emb("🍕")
        XCTAssertGreaterThan(cosine(cat1, cat2), cosine(cat1, dog))
        XCTAssertGreaterThan(cosine(cat1, cat2), cosine(cat1, pizza))
    }

    /// トークナイザ出力とテキストどうしの意味的近さ。
    func testTokenizerAndTextDiscrimination() throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "models not bundled")
        let tokenizer = try XCTUnwrap(CLIPTokenizer.shared)
        let tokens = tokenizer.encode("a photo of a cat")
        func text(_ s: String) throws -> [Float] {
            try XCTUnwrap(MobileCLIPRuntime.shared.encodeText(tokenizer.encode(s)))
        }
        let cat = try text("a photo of a cat")
        let kitten = try text("a photo of a kitten")
        let car = try text("a photo of a car")
        XCTAssertEqual(Array(tokens.prefix(7)), [49406, 320, 1125, 539, 320, 2368, 49407])
        XCTAssertEqual(tokens.count, 77)
        XCTAssertGreaterThan(cosine(cat, kitten), cosine(cat, car))
    }

    // MARK: - オープン語彙の自然文検索（語彙リスト無し）

    /// 候補リストを使わず、任意の自然文クエリが正しい画像に近づくことを検証する。
    /// 「走っている犬」のような表現でも、語彙制約なしに画像とマッチする（本機能の核）。
    func testOpenVocabularyNaturalLanguageMatch() throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "models not bundled")
        let tokenizer = try XCTUnwrap(CLIPTokenizer.shared)
        func textEmb(_ s: String) throws -> [Float] {
            try XCTUnwrap(MobileCLIPRuntime.shared.encodeText(tokenizer.encode(s)))
        }
        let dog = try XCTUnwrap(MobileCLIPRuntime.shared.encodeImage(image(emoji: "🐶")))
        let runningDog = try textEmb("a photo of a running dog")
        let cityStreet = try textEmb("a photo of a city street at night")
        // 自由な自然文（語彙に無い表現）でも、内容に合うクエリの方が近い。
        XCTAssertGreaterThan(cosine(dog, runningDog), cosine(dog, cityStreet))
    }

    // MARK: - 翻訳・キャプション（言語適応）

    /// 英語（ASCII）クエリはそのまま通す（翻訳前段の素通し動作）。
    func testTranslatorPassthroughForEnglish() async {
        let translator = AppQueryTranslator()
        let out = await translator.toEnglish("a running child on the beach")
        XCTAssertEqual(out, "a running child on the beach")
    }

    /// 表示専用 CLIP ラベラ：保存済み埋め込み（Data）から正しいキーワードを上位に出す。
    func testDisplayLabelerProducesRelevantTags() async throws {
        try XCTSkipUnless(MobileCLIPRuntime.shared.isAvailable, "models not bundled")
        let labeler = CLIPDisplayLabeler()
        for (emoji, expected) in [("🐶", "dog"), ("🍕", "pizza"), ("🚗", "car")] {
            let embedding = try XCTUnwrap(MobileCLIPRuntime.shared.encodeImage(image(emoji: emoji)))
            let data = ClipMath.encode(embedding)
            let tags = await labeler.labels(forEmbedding: data)
            XCTAssertTrue(tags.contains(expected), "\(emoji) expected '\(expected)' but got \(tags)")
        }
    }

}
