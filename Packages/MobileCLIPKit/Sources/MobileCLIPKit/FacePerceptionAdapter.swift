import AutoAlbumCore
import CoreGraphics
import CoreImage
import Foundation
import MosaicSupport
import Vision

/// `FacePerceptionProvider` の実体。Vision で顔を検出し、顔を切り抜いて同梱 Core ML 顔モデルで
/// identity 埋め込みを得る。端末写真（"L-…"）は 640px で、クラウド（"C-…"）は `cloudImage` 経由の
/// キャッシュ済みサムネ（w128h128・追加DL無し）で処理する。クラウドは低解像度なので**大きく写った顔
/// 中心**（集合写真・引きの顔は苦手）＝品質は割り切り（ADR: option B）。
/// 顔モデル未同梱なら `isAvailable == false`／空を返し、ピープルは無効になるだけ。
public struct FacePerceptionAdapter: FacePerceptionProvider {
    /// クラウド path → CGImage（Dropbox のキャッシュ済み 128px サムネ）。nil なら端末写真のみ対象。
    let cloudImage: (@Sendable (String) async -> CGImage?)?

    public init(cloudImage: (@Sendable (String) async -> CGImage?)? = nil) {
        self.cloudImage = cloudImage
    }

    public var isAvailable: Bool { FaceModel.modelBundled && FaceModelRuntime.shared.isAvailable }

    public func detectFaces(refKeys: [String]) async -> [String: [DetectedFaceSignal]] {
        var result: [String: [DetectedFaceSignal]] = [:]
        var loaded = 0, nilImage = 0, rawFaces = 0, embedded = 0, visionErr = 0
        var lastError: String?
        for refKey in refKeys {
            guard let ref = PhotoRef.decode(refKey) else { continue }
            let source: CGImage?
            if let localID = ref.localIdentifier {
                // 端末写真: 顔検出に十分な 640px。T3: 800→640px でロード/メモリを約36%削減
                // （顔クロップは検出後に bbox 基準で切るため embedding 品質への影響は軽微）。
                source = await loadLocalCGImage(localID, maxPixel: 640)
            } else if let path = ref.cloudPath, let cloudImage {
                // クラウド: キャッシュ済み 128px サムネを再利用（追加ダウンロード無し・低解像度）。
                source = await cloudImage(path)
            } else {
                source = nil
            }
            guard let cg = source else { nilImage += 1; continue }
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

    /// 戻り値 `.raw` は検出した顔数（フィルタ前）、`.signals` は埋め込みまで成功した顔、
    /// `.error` は Vision が使えず CIDetector にフォールバックした場合のメッセージ（切り分け用）。
    private func detect(in cg: CGImage) -> (raw: Int, signals: [DetectedFaceSignal], error: String?) {
        let (boxes, error) = faceBoxes(in: cg)   // 正規化(原点左下)の顔矩形

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        var signals: [DetectedFaceSignal] = []
        for box in boxes {
            // 小さすぎる顔は埋め込み精度が低いので除外。
            guard box.width >= 0.05, box.height >= 0.05 else { continue }
            guard let crop = cropFace(cg, normalizedBox: box, width: width, height: height),
                  let embedding = FaceModelRuntime.shared.embed(crop) else { continue }
            signals.append(DetectedFaceSignal(
                boundingBox: box,
                embedding: ClipMath.encodeHalf(embedding),
                quality: 1))
        }
        return (boxes.count, signals, error)
    }

    /// 顔矩形（Vision 正規化・原点左下）を返す。まず Vision（実機・高精度）、失敗（シミュレータの
    /// "Could not create inference context" 等）なら CIDetector（Core Image・CPU・どこでも動く）へ。
    private func faceBoxes(in cg: CGImage) -> (boxes: [CGRect], error: String?) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([request])
            return ((request.results ?? []).map(\.boundingBox), nil)
        } catch {
            return (ciFaceBoxes(in: cg), error.localizedDescription)
        }
    }

    /// CIDetector による顔検出（シミュレータでも動く CPU 実装）。返り値は Vision と同じ
    /// 正規化・原点左下の矩形。`CIFaceFeature.bounds` は画像座標・原点左下なので W/H で割る。
    private func ciFaceBoxes(in cg: CGImage) -> [CGRect] {
        let ci = CIImage(cgImage: cg)
        let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ci) ?? []
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return [] }
        return features.compactMap { $0 as? CIFaceFeature }.map {
            CGRect(x: $0.bounds.origin.x / width, y: $0.bounds.origin.y / height,
                   width: $0.bounds.width / width, height: $0.bounds.height / height)
        }
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
