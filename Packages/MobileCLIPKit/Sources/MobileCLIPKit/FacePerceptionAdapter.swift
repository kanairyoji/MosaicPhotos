import AutoAlbumCore
import CoreGraphics
import Foundation
import MosaicSupport
import Vision

/// `FacePerceptionProvider` の実体。Vision で顔を検出し、顔を切り抜いて同梱 Core ML 顔モデルで
/// identity 埋め込みを得る。端末写真（"L-…"）のみ対応（ローカルから画像取得）。
/// 顔モデル未同梱なら `isAvailable == false`／空を返し、ピープルは無効になるだけ。
public struct FacePerceptionAdapter: FacePerceptionProvider {
    public init() {}

    public var isAvailable: Bool { FaceModel.modelBundled && FaceModelRuntime.shared.isAvailable }

    public func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
        var result: [String: [DetectedFaceSignal]] = [:]
        for refKey in refKeys {
            guard let ref = PhotoRef.decode(refKey), let localID = ref.localIdentifier else { continue }
            // 顔検出に十分な解像度で取得（大きすぎると重いので 800px 程度）。
            guard let cg = await loadLocalCGImage(localID, maxPixel: 800) else { continue }
            result[refKey] = detect(in: cg)
        }
        return result
    }

    private func detect(in cg: CGImage) -> [DetectedFaceSignal] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        guard (try? handler.perform([request])) != nil, let faces = request.results else { return [] }

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        var signals: [DetectedFaceSignal] = []
        for face in faces {
            // 小さすぎる顔は埋め込み精度が低いので除外。
            guard face.boundingBox.width >= 0.05, face.boundingBox.height >= 0.05 else { continue }
            guard let crop = cropFace(cg, normalizedBox: face.boundingBox, width: width, height: height),
                  let embedding = FaceModelRuntime.shared.embed(crop) else { continue }
            signals.append(DetectedFaceSignal(
                boundingBox: face.boundingBox,
                embedding: ClipMath.encodeHalf(embedding),
                quality: face.confidence))
        }
        return signals
    }

    /// Vision の正規化 bbox（原点左下・y 上向き）→ CGImage のピクセル矩形（原点左上）へ変換し、
    /// 顔の周囲にマージンを付けて切り抜く（顔モデルは輪郭周辺も使うため）。
    private func cropFace(_ cg: CGImage, normalizedBox: CGRect, width: CGFloat, height: CGFloat) -> CGImage? {
        let margin: CGFloat = 0.3
        var box = normalizedBox.insetBy(dx: -normalizedBox.width * margin, dy: -normalizedBox.height * margin)
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull else { return nil }
        let pixel = CGRect(
            x: box.origin.x * width,
            y: (1 - box.origin.y - box.height) * height,   // y 反転
            width: box.width * width,
            height: box.height * height).integral
        guard pixel.width >= 1, pixel.height >= 1 else { return nil }
        return cg.cropping(to: pixel)
    }
}
