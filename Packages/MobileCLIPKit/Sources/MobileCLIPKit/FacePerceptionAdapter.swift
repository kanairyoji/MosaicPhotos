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
        var loaded = 0, nilImage = 0, rawFaces = 0, embedded = 0, visionErr = 0
        var lastError: String?
        for refKey in refKeys {
            guard let ref = PhotoRef.decode(refKey), let localID = ref.localIdentifier else { continue }
            // 顔検出に十分な解像度で取得（大きすぎると重いので 800px 程度）。
            guard let cg = await loadLocalCGImage(localID, maxPixel: 800) else { nilImage += 1; continue }
            loaded += 1
            let (raw, signals, error) = detect(in: cg)
            if let error { visionErr += 1; lastError = error }
            rawFaces += raw
            embedded += signals.count
            result[refKey] = signals
        }
        // 切り分け用: 画像ロード成否・Vision 生検出数・埋め込み成功数・Vision エラー。
        Diagnostics.mark("faces.detect: loaded=\(loaded) nil=\(nilImage) rawFaces=\(rawFaces) "
                         + "embedded=\(embedded) visionErr=\(visionErr)\(lastError.map { " (\($0))" } ?? "")")
        return result
    }

    /// 戻り値 `.raw` は Vision が検出した顔数（フィルタ前）、`.signals` は埋め込みまで成功した顔、
    /// `.error` は Vision の perform 失敗（シミュレータ非対応など）を切り分けるためのメッセージ。
    private func detect(in cg: CGImage) -> (raw: Int, signals: [DetectedFaceSignal], error: String?) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return (0, [], error.localizedDescription)
        }
        guard let faces = request.results else { return (0, [], nil) }

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
        return (faces.count, signals, nil)
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
