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
                // 端末写真: 1024px（ADR-51・旧 640px）。集合写真の端の小さい顔も埋め込みに
                // 足る解像度を確保する。メモリ増（約2.6倍/枚）は夜間・1枚ずつ処理＋
                // メモリ圧迫ゲート（shouldPause）で吸収する。
                source = await loadLocalCGImage(localID, maxPixel: 1024)
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

    /// 1 顔分の観測（矩形・品質・向き・目閉じ・笑顔・両目中心）。
    private struct FaceObservation {
        var box: CGRect
        var quality: Float
        /// 顔検出そのものの信頼度（VNFaceObservation.confidence・フォールバックは 1）。
        var confidence: Float = 1
        var yaw: Float?
        var roll: Float?
        var eyesClosed: Bool?
        var hasSmile: Bool?
        /// 両目の中心（ピクセル・原点左下）。アライメント切り抜き（ADR-51）に使う。
        var eyeLeft: CGPoint?
        var eyeRight: CGPoint?
    }

    /// 戻り値 `.raw` は検出した顔数（フィルタ前）、`.signals` は埋め込みまで成功した顔、
    /// `.error` は Vision が使えず CIDetector にフォールバックした場合のメッセージ（切り分け用）。
    /// face-info-expansion: 顔向き（yaw/roll）・目閉じ・笑顔を追加取得し、
    /// 品質を `FaceQualityGate` で一元調整する（横顔はフロア未満＝クラスタへ入れない）。
    private func detect(in cg: CGImage, isCloud: Bool) -> (raw: Int, signals: [DetectedFaceSignal], error: String?) {
        let (analyses, error) = analyzeFaces(in: cg, isCloud: isCloud)
        return (analyses.count, analyses.compactMap(\.signal), error)
    }

    /// 顔ゲートの判定レポート（検証ハーネス・Developer 用の公開型）。
    /// 「どの顔が・どの理由で・どの数値で」通過/棄却されたかを 1 顔ずつ返す。
    public struct FaceGateReport: Sendable {
        public let pixelSize: CGSize
        public let confidence: Float
        public let rawQuality: Float
        public let adjustedQuality: Float
        public let blurVariance: Float?
        public let meanLuma: Float?
        public let yaw: Float?
        public let roll: Float?
        public let accepted: Bool
        /// 棄却理由: size-ratio / size-pixels / low-confidence / crop-failed / not-a-face /
        /// embed-failed。通過は nil（adjustedQuality がフロア未満なら「記録のみ・クラスタ不参加」）。
        public let rejectReason: String?
    }

    /// 画像 1 枚をゲート込みで解析してレポートを返す（**検証ハーネス用**・埋め込み含む本番同一経路）。
    /// 端末へ入れて大量スキャンせずとも、問題写真をフォルダに置いてしきい値を素早く調整できる。
    public func debugAnalyze(_ cg: CGImage, isCloud: Bool = false) -> [FaceGateReport] {
        analyzeFaces(in: cg, isCloud: isCloud).analyses.map(\.report)
    }

    private struct FaceAnalysis {
        var report: FaceGateReport
        var signal: DetectedFaceSignal?
    }

    private func analyzeFaces(in cg: CGImage, isCloud: Bool) -> (analyses: [FaceAnalysis], error: String?) {
        let (faces, error) = faceObservations(in: cg)   // 正規化(原点左下)の矩形＋品質＋向き＋属性

        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        // 小さすぎる顔は埋め込み精度が低いので除外（クラウドは低解像度サムネのため大きい顔のみ）。
        let minSide = FaceQualityGate.minFaceSide(isCloud: isCloud)
        var out: [FaceAnalysis] = []
        for face in faces {
            let pixelBox = CGRect(x: face.box.origin.x * width, y: face.box.origin.y * height,
                                  width: face.box.width * width, height: face.box.height * height)
            var reason: String?
            var signal: DetectedFaceSignal?
            var metrics: (blurVariance: Float, meanLuma: Float)?
            var adjusted = face.quality

            if face.box.width < minSide || face.box.height < minSide {
                reason = "size-ratio"
            } else if pixelBox.width < FaceQualityGate.minFacePixels
                        || pixelBox.height < FaceQualityGate.minFacePixels {
                // 比率を満たしても実ピクセルが小さすぎる顔は埋め込みが機能しない（二段構え）。
                reason = "size-pixels"
            } else if face.confidence < FaceQualityGate.minDetectionConfidence {
                // ADR-53: 検出信頼度が低い「顔でない」誤検出（模様・ぼけた物体）を弾く。
                reason = "low-confidence"
            } else {
                // ADR-51: 両目ランドマークがあればアライメント切り抜き（目線を水平・標準位置へ）。
                // 計画不能（過大な傾き等）は従来の bbox 切り抜きへフォールバック。
                let aligned: CGImage? = {
                    guard let l = face.eyeLeft, let r = face.eyeRight,
                          let plan = FaceAlignment.plan(leftEye: l, rightEye: r, pixelBox: pixelBox)
                    else { return nil }
                    return alignedCrop(cg, plan: plan)
                }()
                let crop = aligned ?? cropFace(cg, normalizedBox: face.box, width: width, height: height)
                if let crop {
                    if !verifyFaceInCrop(crop) {
                        // ADR-53: 顔中心のクロップ内で再検出できない＝顔でない（二段検出）。
                        reason = "not-a-face"
                    } else {
                        // ADR-45/47/52: 実品質に顔向き・目閉じ・ぼけ・露出の減衰を適用。
                        // フロア未満は未割当（記録のみ・重心を汚さない）。
                        metrics = Self.faceMetrics(crop)
                        adjusted = FaceQualityGate.adjustedQuality(
                            quality: face.quality, yaw: face.yaw, roll: face.roll,
                            eyesClosed: face.eyesClosed,
                            blurVariance: metrics?.blurVariance, meanLuma: metrics?.meanLuma)
                        if let embedding = FaceModelRuntime.shared.embed(crop) {
                            signal = DetectedFaceSignal(
                                boundingBox: face.box,
                                embedding: ClipMath.encodeHalf(embedding),
                                quality: adjusted,
                                hasSmile: face.hasSmile)
                        } else {
                            reason = "embed-failed"
                        }
                    }
                } else {
                    reason = "crop-failed"
                }
            }
            out.append(FaceAnalysis(
                report: FaceGateReport(pixelSize: pixelBox.size,
                                       confidence: face.confidence,
                                       rawQuality: face.quality,
                                       adjustedQuality: adjusted,
                                       blurVariance: metrics?.blurVariance,
                                       meanLuma: metrics?.meanLuma,
                                       yaw: face.yaw, roll: face.roll,
                                       accepted: signal != nil,
                                       rejectReason: reason),
                signal: signal))
        }
        return (out, error)
    }

    /// クロップ再検証（ADR-53）: 顔中心に切り抜いた画像内でもう一度顔検出し、
    /// 実際に顔があるか確認する（模様・物体の誤検出はここで落ちる）。クロップは顔中心なので
    /// 検出顔がクロップ幅の一定割合以上を占めることを要求する。Vision が使えない環境
    ///（シミュレータの一部）では判定不能＝棄却しない。
    private func verifyFaceInCrop(_ crop: CGImage) -> Bool {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil else { return true }
        guard let results = request.results, !results.isEmpty else { return false }
        return results.contains { $0.boundingBox.width >= FaceQualityGate.cropVerifyMinSide }
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
            let imageSize = CGSize(width: cg.width, height: cg.height)
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
                                       confidence: o.confidence,
                                       yaw: yaw, roll: roll,
                                       eyesClosed: eyesClosed, hasSmile: smile,
                                       eyeLeft: Self.regionCenter(lm?.landmarks?.leftEye, imageSize: imageSize),
                                       eyeRight: Self.regionCenter(lm?.landmarks?.rightEye, imageSize: imageSize))
            }
            return (faces, nil)
        } catch {
            // フォールバック 1: 矩形のみ（品質は取れないので 1）。
            let rectRequest = VNDetectFaceRectanglesRequest()
            if (try? handler.perform([rectRequest])) != nil, let rects = rectRequest.results {
                return (rects.map {
                    FaceObservation(box: $0.boundingBox, quality: 1, confidence: $0.confidence,
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

    /// 顔クロップの画質指標（ぼけ・露出）。64px 正方のグレースケールへ縮小して輝度を取り、
    /// 計算自体は純ロジック（`FaceImageMetrics`）に委譲する（クロップサイズ非依存のスケール）。
    private static func faceMetrics(_ crop: CGImage) -> (blurVariance: Float, meanLuma: Float)? {
        let side = 64
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: side * side)
        var luma = [Float](repeating: 0, count: side * side)
        for i in 0..<(side * side) { luma[i] = Float(buffer[i]) }
        return FaceImageMetrics.compute(luma: luma, width: side, height: side)
    }

    /// ランドマーク領域の中心（ピクセル・原点左下）。
    private static func regionCenter(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// アライメント切り抜き（ADR-51）。計画（回転角・出力辺・目標位置）どおりに
    /// CGContext で回転描画する。CGContext は原点左下（y 上向き）＝計画と同じ座標系。
    private func alignedCrop(_ cg: CGImage, plan: FaceAlignmentPlan) -> CGImage? {
        let side = Int(plan.side.rounded())
        guard side >= 16 else { return nil }
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: plan.target.x, y: plan.target.y)
        ctx.rotate(by: -plan.angle)
        ctx.translateBy(x: -plan.eyeMid.x, y: -plan.eyeMid.y)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
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
