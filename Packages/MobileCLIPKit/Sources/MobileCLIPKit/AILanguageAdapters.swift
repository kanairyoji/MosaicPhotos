import AutoAlbumCore
import CoreGraphics
import MosaicSupport
import Photos
import UIKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// 任意言語の検索文を英語へ正規化する（CLIP は英語学習のため）。
/// iOS 26 + Apple Intelligence 端末では Foundation Models（オンデバイス LLM）で翻訳。
/// 既に英語、または FM 非対応なら原文をそのまま返す（CLIP は英語前提なので最善努力）。
public struct AppQueryTranslator: QueryTranslator {
    public init() {}

    public func toEnglish(_ text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        if trimmed.allSatisfy({ $0.isASCII }) { return trimmed }   // 既に英語（ASCII）

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            // ⚠️ LLM のセッション生成＋推論は Task.detached で確実にオフメイン化する。
            let out: String? = await Task.detached(priority: .utility) {
                let session = LanguageModelSession(
                    instructions: "Translate the user's text into natural English for an image search query. "
                        + "Reply with ONLY the English translation — no quotes, no explanation.")
                let response = try? await session.respond(to: trimmed)
                return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }.value
            if let out, !out.isEmpty { return out }
        }
        #endif
        return trimmed
    }
}

/// PHAsset（localIdentifier）→ CGImage をメインスレッド外で読み込む共通ヘルパ（CLIP 埋め込み用）。
/// 実体は `MosaicSupport.PHAssetImageLoader`（向き正規化・二重 resume 防止を内包）に委譲。
nonisolated func loadLocalCGImage(_ localIdentifier: String, maxPixel: CGFloat = 512) async -> CGImage? {
    // renderFloor: 0 で従来どおりの入力サイズを維持（CLIP 埋め込み・顔検出の入力を変えない）。
    await PHAssetImageLoader.cgImage(localIdentifier: localIdentifier, maxPixel: maxPixel,
                                     allowsNetwork: false, renderFloor: 0)
}

/// UIImage → 向きを **.up に正規化した** CGImage（互換名・実体は共通ローダへ委譲）。
///
/// ⚠️ `UIImage.cgImage` は EXIF 回転が**未適用の生ビットマップ**のことがある（HEIC 等・
/// PHImageManager はターゲットサイズにより回転適用済み/未適用のどちらも返し得る）。
/// 生のまま使うと、検出時と表示時で別表現を掴んだ写真だけ顔矩形がズレる（実障害）。
/// すべての CGImage 化をこの関数に通し、座標系を常に「表示と同じ向き」に揃える。
public func orientationNormalizedCGImage(_ image: UIImage) -> CGImage? {
    PHAssetImageLoader.normalizedUpCGImage(image)
}
