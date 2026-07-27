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
            let (raw, signals, error) = detect(in: cg, isCloud: ref.localIdentifier == nil)
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

    /// 1 顔分の観測（矩形・品質・向き・目閉じ・笑顔）。
    private struct FaceObservation {
        var box: CGRect
        var quality: Float
        var yaw: Float?
        var roll: Float?
        var eyesClosed: Bool?
        var hasSmile: Bool?
    }

    /// 戻り値 `.raw` は検出した顔数（フィルタ前）、`.signals` は埋め込みまで成功した顔、
    /// `.error` は Vision が使えず CIDetector にフォールバックした場合のメッセージ（切り分け用）。
    /// face-info-expansion: 顔向き（yaw/roll）・目閉じ・笑顔を追加取得し、
    /// 品質を `FaceQualityGate` で一元調整する（横顔はフロア未満＝クラスタへ入れない）。
    private func detect(in cg: CGImage, isCloud: Bool) -> (raw: Int, signals: [DetectedFaceSignal], error: String?) {
        let (faces, error) = faceObservations(in: cg)   // 正規化(原点左下)の矩形＋品質＋向き＋属性

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        // 小さすぎる顔は埋め込み精度が低いので除外（クラウドは低解像度サムネのため大きい顔のみ）。
        let minSide = FaceQualityGate.minFaceSide(isCloud: isCloud)
        var signals: [DetectedFaceSignal] = []
        for face in faces {
            guard face.box.width >= minSide, face.box.height >= minSide else { continue }
            guard let crop = cropFace(cg, normalizedBox: face.box, width: width, height: height),
                  let embedding = FaceModelRuntime.shared.embed(crop) else { continue }
            // ADR-45/47: 実品質（faceCaptureQuality）に顔向き・目閉じの減衰を適用して伝える。
            // 横顔・大傾きはフロア未満（未割当）になり、重心を汚さない。
            let adjusted = FaceQualityGate.adjustedQuality(
                quality: face.quality, yaw: face.yaw, roll: face.roll, eyesClosed: face.eyesClosed)
            signals.append(DetectedFaceSignal(
                boundingBox: face.box,
                embedding: ClipMath.encodeHalf(embedding),
                quality: adjusted,
                hasSmile: face.hasSmile))
        }
        return (faces.count, signals, error)
    }

    /// 顔観測（Vision 正規化・原点左下）を返す。**1 回の perform** で品質＋ランドマークを取得し、
    /// 失敗（シミュレータの "Could not create inference context" 等）なら顔矩形のみ→CIDetector に
    /// フォールバック（品質は 1＝中立。実機はほぼ常に品質つきで取れる）。
    /// 笑顔は CIDetector（CIDetectorSmile）を 1 パス追加して bbox で照合する。
    private func faceObservations(in cg: CGImage) -> (faces: [FaceObservation], error: String?) {
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        do {
            try handler.perform([qualityRequest, landmarksRequest])
            let obs = qualityRequest.results ?? []
            guard !obs.isEmpty else { return ([], nil) }   // 顔なし（エラーではない）
            let landmarks = landmarksRequest.results ?? []
            let smiles = ciSmileBoxes(in: cg)
            let faces = obs.map { o -> FaceObservation in
                // ランドマーク観測は bbox の重なり（IoU 最大）で対応づける。
                let lm = Self.bestMatch(for: o.boundingBox, in: landmarks.map(\.boundingBox))
                    .map { landmarks[$0] }
                let yaw = (lm?.yaw ?? o.yaw)?.floatValue
                let roll = (lm?.roll ?? o.roll)?.floatValue
                let eyesClosed = lm?.landmarks.flatMap { Self.eyesClosed($0) }
                let smile = Self.bestMatch(for: o.boundingBox, in: smiles.map(\.box))
                    .map { smiles[$0].hasSmile }
                return FaceObservation(box: o.boundingBox,
                                       quality: o.faceCaptureQuality ?? 1,
                                       yaw: yaw, roll: roll,
                                       eyesClosed: eyesClosed, hasSmile: smile)
            }
            return (faces, nil)
        } catch {
            // フォールバック 1: 矩形のみ（品質は取れないので 1）。
            let rectRequest = VNDetectFaceRectanglesRequest()
            if (try? handler.perform([rectRequest])) != nil, let rects = rectRequest.results {
                return (rects.map {
                    FaceObservation(box: $0.boundingBox, quality: 1,
                                    yaw: $0.yaw?.floatValue, roll: $0.roll?.floatValue,
                                    eyesClosed: nil, hasSmile: nil)
                }, error.localizedDescription)
            }
            // フォールバック 2: CIDetector（シミュレータ）。笑顔も同時に取れる。
            return (ciSmileBoxes(in: cg).map {
                FaceObservation(box: $0.box, quality: 1, yaw: nil, roll: nil,
                                eyesClosed: nil, hasSmile: $0.hasSmile)
            }, error.localizedDescription)
        }
    }

    /// IoU 最大（> 0.3）の候補 index。ランドマーク/笑顔観測を品質観測へ対応づける。
    private static func bestMatch(for box: CGRect, in candidates: [CGRect]) -> Int? {
        var best: (index: Int, iou: CGFloat)?
        for (i, c) in candidates.enumerated() {
            let inter = box.intersection(c)
            guard !inter.isNull else { continue }
            let interArea = inter.width * inter.height
            let unionArea = box.width * box.height + c.width * c.height - interArea
            guard unionArea > 0 else { continue }
            let iou = interArea / unionArea
            if iou > 0.3, iou > (best?.iou ?? 0) { best = (i, iou) }
        }
        return best?.index
    }

    /// ランドマークから目閉じを近似する（左右とも縦横比 < 0.15 なら閉眼）。
    /// ランドマークが取れない場合は nil（判定しない）。
    private static func eyesClosed(_ landmarks: VNFaceLandmarks2D) -> Bool? {
        func openness(_ region: VNFaceLandmarkRegion2D?) -> CGFloat? {
            guard let points = region?.normalizedPoints, points.count >= 4 else { return nil }
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(),
                  let minY = ys.min(), let maxY = ys.max(), maxX > minX else { return nil }
            return (maxY - minY) / (maxX - minX)
        }
        guard let left = openness(landmarks.leftEye), let right = openness(landmarks.rightEye) else {
            return nil
        }
        return left < 0.15 && right < 0.15
    }

    /// CIDetector（笑顔つき）による顔検出。返り値は Vision と同じ正規化・原点左下の矩形。
    /// `CIFaceFeature.bounds` は画像座標・原点左下なので W/H で割る。
    private func ciSmileBoxes(in cg: CGImage) -> [(box: CGRect, hasSmile: Bool)] {
        let ci = CIImage(cgImage: cg)
        let detector = CIDetector(ofType: CIDetectorTypeFace, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: ci, options: [CIDetectorSmile: true]) ?? []
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        guard width > 0, height > 0 else { return [] }
        return features.compactMap { $0 as? CIFaceFeature }.map {
            (CGRect(x: $0.bounds.origin.x / width, y: $0.bounds.origin.y / height,
                    width: $0.bounds.width / width, height: $0.bounds.height / height),
             $0.hasSmile)
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
