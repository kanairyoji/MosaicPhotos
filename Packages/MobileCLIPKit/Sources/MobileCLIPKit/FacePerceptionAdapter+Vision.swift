import AutoAlbumCore
import CoreGraphics
import CoreImage
import Foundation
import MosaicSupport
import UIKit
import Vision

// MARK: - Vision の観測と切り抜き
//
// `FacePerceptionAdapter` のうち、**Vision で顔を観測し、埋め込み用に切り抜く**部分をここに分ける。
// 本体（`FacePerceptionAdapter.swift`）は「候補をどう組み立て、どう埋め込むか」に専念する。
// ⚠️ 1 ファイル 606 行で、パイプライン（何を・どの順で）と画像処理（どう切るか）が同居していた。
// 振る舞いは変えていない（純粋な分割）。

extension FacePerceptionAdapter {

    /// クロップ再検証（ADR-53）: 顔中心に切り抜いた画像内でもう一度顔検出し、
    /// 実際に顔があるか確認する（模様・物体の誤検出はここで落ちる）。クロップは顔中心なので
    /// 検出顔がクロップ幅の一定割合以上を占めることを要求する。Vision が使えない環境
    ///（シミュレータの一部）では判定不能＝棄却しない。
    func verifyFaceInCrop(_ crop: CGImage) async -> Bool {
        await MLInferenceGate.shared.run {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: crop, options: [:])
            guard (try? handler.perform([request])) != nil else { return true }
            guard let results = request.results, !results.isEmpty else { return false }
            return results.contains { $0.boundingBox.width >= FaceQualityGate.cropVerifyMinSide }
        }
    }

    /// 顔観測（Vision 正規化・原点左下）を返す。**1 回の perform** で品質＋ランドマークを取得し、
    /// 失敗（シミュレータの "Could not create inference context" 等）なら顔矩形のみ→CIDetector に
    /// フォールバック（品質は 1＝中立。実機はほぼ常に品質つきで取れる）。
    /// 笑顔は CIDetector（CIDetectorSmile）を 1 パス追加して bbox で照合する。
    func faceObservations(in cg: CGImage) async -> (faces: [FaceObservation], error: String?) {
        await MLInferenceGate.shared.run { self.unsafeFaceObservations(in: cg) }
    }

    /// **計測用**: 品質ゲートを通さない生の検出結果を返す（ADR-89）。
    /// 歩留まり計測は「どのゲートで何が落ちているか」を知るのが目的なので、
    /// 本番と**同じ Vision 設定**で検出だけ行い、採否は呼び出し側（`FaceYieldMeasurement`）が
    /// サイズ別に算術で判定する。埋め込みは作らない（速い）。
    public func observeFacesForMeasurement(in cg: CGImage) async -> [FaceYieldMeasurement.FaceObservation] {
        let (faces, _) = await faceObservations(in: cg)
        return faces.map {
            FaceYieldMeasurement.FaceObservation(
                normalizedShortSide: min($0.box.width, $0.box.height),
                confidence: $0.confidence,
                quality: $0.quality)
        }
    }

    /// ゲート保持済み前提の本体（入れ子で `run` を呼ばないこと）。
    func unsafeFaceObservations(in cg: CGImage) -> (faces: [FaceObservation], error: String?) {
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
                                       eyeRight: Self.regionCenter(lm?.landmarks?.rightEye, imageSize: imageSize),
                                       nose: Self.regionCenter(lm?.landmarks?.nose, imageSize: imageSize),
                                       mouthLeft: Self.lipCorner(lm?.landmarks?.outerLips, imageSize: imageSize, left: true),
                                       mouthRight: Self.lipCorner(lm?.landmarks?.outerLips, imageSize: imageSize, left: false))
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
    static func faceMetrics(_ crop: CGImage) -> (blurVariance: Float, meanLuma: Float)? {
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

    /// 口角（外唇の x 最小/最大の点・ピクセル座標）。ArcFace 5 点整列（ADR-70）用。
    private static func lipCorner(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize,
                                  left: Bool) -> CGPoint? {
        guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty else { return nil }
        return left ? points.min { $0.x < $1.x } : points.max { $0.x < $1.x }
    }

    /// ArcFace 5 点整列の切り抜き（ADR-70）。相似変換（画像ピクセル→112×112 出力・
    /// どちらも原点左下）を CGContext に連結して描くだけ。テンプレート位置に目・鼻・口が揃う。
    func arcFaceCrop(_ cg: CGImage, transform: CGAffineTransform) -> CGImage? {
        let side = FaceAlignment.arcFaceOutputSide
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.concatenate(transform)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return ctx.makeImage()
    }

    /// アライメント切り抜き（ADR-51）。計画（回転角・出力辺・目標位置）どおりに
    /// CGContext で回転描画する。CGContext は原点左下（y 上向き）＝計画と同じ座標系。
    func alignedCrop(_ cg: CGImage, plan: FaceAlignmentPlan) -> CGImage? {
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

    /// 笑顔検出用の CIDetector（**使い回す**）。
    /// ⚠️ 以前は写真ごとに `CIDetector(ofType:context: nil, options:)` を生成していた。`context: nil` は
    /// 呼び出しごとに `CIContext` を作るため、顔のある写真すべてでコンテキスト構築コストを払っていた。
    /// CIDetector は生成後 immutable でスレッドセーフ（かつ本経路は ANE ゲートで直列化済み）。
    private static let smileDetector: CIDetector? = CIDetector(
        ofType: CIDetectorTypeFace, context: CIContext(options: nil),
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

    /// CIDetector（笑顔つき）による顔検出。返り値は Vision と同じ正規化・原点左下の矩形。
    /// `CIFaceFeature.bounds` は画像座標・原点左下なので W/H で割る。
    /// 笑顔は `FaceStore` の代表顔スコア（`quality + hasSmile*0.3 + …`）に効くので、Vision で顔が
    /// 取れている写真に対してのみ、この 2 本目のパスを走らせる（呼び出し側で顔ゼロは弾いている）。
    func ciSmileBoxes(in cg: CGImage) -> [(box: CGRect, hasSmile: Bool)] {
        let ci = CIImage(cgImage: cg)
        let features = Self.smileDetector?.features(in: ci, options: [CIDetectorSmile: true]) ?? []
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
    func cropFace(_ cg: CGImage, normalizedBox: CGRect, width: CGFloat, height: CGFloat) -> CGImage? {
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
