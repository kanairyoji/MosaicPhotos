import AutoAlbumCore
import CoreGraphics
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
            let session = LanguageModelSession(
                instructions: "Translate the user's text into natural English for an image search query. "
                    + "Reply with ONLY the English translation — no quotes, no explanation.")
            if let response = try? await session.respond(to: trimmed) {
                let out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
            }
        }
        #endif
        return trimmed
    }
}

/// PHAsset（localIdentifier）→ CGImage をメインスレッド外で読み込む共通ヘルパ（CLIP 埋め込み用）。
nonisolated func loadLocalCGImage(_ localIdentifier: String, maxPixel: CGFloat = 512) async -> CGImage? {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
        return nil
    }
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    let target = CGSize(width: maxPixel, height: maxPixel)
    return await withCheckedContinuation { continuation in
        PHImageManager.default().requestImage(
            for: asset, targetSize: target, contentMode: .aspectFit, options: options
        ) { image, _ in
            continuation.resume(returning: image?.cgImage)
        }
    }
}
