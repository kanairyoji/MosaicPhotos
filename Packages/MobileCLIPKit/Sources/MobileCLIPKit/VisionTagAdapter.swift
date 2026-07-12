import AutoAlbumCore
import CoreGraphics
import Foundation
import MosaicSupport
import Vision

/// `TagPerceptionProvider` の実体。
/// - シーンタグ: **OS 内蔵の Vision 画像分類**（`VNClassifyImageRequest`・約1,300クラス）。
///   信頼度は Apple が校正済みで、`hasMinimumRecall(_:forPrecision:)` により
///   「精度 0.9 を満たすタグだけ採る」という**原理的な足切り**ができる（自前閾値が不要）。
/// - キャプション: Florence-2-base（同梱時のみ・`VLMRuntime`）。
public struct VisionTagAdapter: TagPerceptionProvider {
    /// クラウド path → CGImage（Dropbox サムネイル）。CLIPEmbeddingProvider と同じ seam。
    let cloudImage: @Sendable (String) async -> CGImage?

    public init(cloudImage: @escaping @Sendable (String) async -> CGImage?) {
        self.cloudImage = cloudImage
    }

    public var isTaggingAvailable: Bool { true }   // Vision 分類は OS 内蔵

    public func sceneTags(refKeys: [String]) async -> [String: [String]] {
        var out: [String: [String]] = [:]
        for refKey in refKeys {
            await Task.yield()
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let cg: CGImage?
            if let localId = ref.localIdentifier {
                cg = await loadLocalCGImage(localId, maxPixel: 384)
            } else if let path = ref.cloudPath {
                cg = await cloudImage(path)
            } else {
                cg = nil
            }
            guard let cg else {
                out[refKey] = []   // 取得不可も「処理済み」にして無限ループを防ぐ
                continue
            }
            out[refKey] = Self.classify(cg)
        }
        return out
    }

    /// Vision 分類 → 精度 0.9 を満たす識別子（最大 10 個・信頼度順）。
    static func classify(_ cg: CGImage) -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        let observations = request.results ?? []
        return observations
            .filter { $0.hasMinimumRecall(0.01, forPrecision: 0.9) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(10)
            .map(\.identifier)
    }

    // MARK: - キャプション（SmolVLM・P3）

    public var isCaptioningAvailable: Bool { VLMRuntime.shared.isAvailable }

    public func captions(refKeys: [String]) async -> [String: String] {
        guard VLMRuntime.shared.isAvailable else { return [:] }
        var out: [String: String] = [:]
        for refKey in refKeys {
            await Task.yield()
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let cg: CGImage?
            if let localId = ref.localIdentifier {
                cg = await loadLocalCGImage(localId, maxPixel: 512)
            } else if let path = ref.cloudPath {
                cg = await cloudImage(path)
            } else {
                cg = nil
            }
            guard let cg else { continue }
            if let caption = await VLMRuntime.shared.caption(for: cg) {
                out[refKey] = caption
            }
        }
        return out
    }
}
