import CoreGraphics
import Foundation

/// 顔アライメント（目の位置正規化）の計画（純ロジック・テスト対象）。
///
/// facenet は「目が水平・標準位置に揃った顔」で学習されているが、bbox の矩形切り抜きだけでは
/// 顔の傾き・頭の位置が写真ごとにバラバラのまま埋め込みに渡り、同一人物でも埋め込みが離れる。
/// 両目のランドマークから「回転角＋切り抜き位置」を決め、目線が水平・両目中点が標準位置
/// （上から 35%・横中央）に来る正方形クロップを計画する。実際の描画（CGContext）は
/// アプリ側（FacePerceptionAdapter）が行う。
///
/// 座標系はすべて **ピクセル・原点左下（y 上向き）**（Vision / CGContext と同じ）。
public struct FaceAlignmentPlan: Sendable, Equatable {
    /// 両目を結ぶ線の傾き（ラジアン）。描画側はこの分だけ**逆回転**して水平にする。
    public let angle: CGFloat
    /// 出力正方形の辺（ピクセル）。
    public let side: CGFloat
    /// 両目の中点（入力画像のピクセル座標）。
    public let eyeMid: CGPoint
    /// 出力内で eyeMid を置く位置（横中央・上から 35% ＝ 下から 65%）。
    public let target: CGPoint
}

/// 顔クロップの画質指標（純ロジック・テスト対象）。ぼけ＝ラプラシアン分散、露出＝平均輝度。
/// 入力は「64px 正方などの固定サイズへ縮小した輝度（0〜255・行優先）」＝クロップの大きさに
/// よらず同じスケールで比較できる（しきい値は FaceQualityGate に集約）。
public enum FaceImageMetrics {
    /// 輝度バッファから（ぼけ分散・平均輝度）を計算する。3×3 未満や不正サイズは nil。
    public static func compute(luma: [Float], width: Int, height: Int)
        -> (blurVariance: Float, meanLuma: Float)? {
        guard width >= 3, height >= 3, luma.count == width * height else { return nil }
        var mean: Float = 0
        for v in luma { mean += v }
        mean /= Float(luma.count)
        // 4 近傍ラプラシアン（エッジ量）。ぼけ画像はエッジが失われ分散が小さくなる。
        var lapSum: Float = 0
        var lapSquaredSum: Float = 0
        var count = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let lap = 4 * luma[i] - luma[i - 1] - luma[i + 1]
                        - luma[i - width] - luma[i + width]
                lapSum += lap
                lapSquaredSum += lap * lap
                count += 1
            }
        }
        let n = Float(count)
        let lapMean = lapSum / n
        let variance = max(0, lapSquaredSum / n - lapMean * lapMean)
        return (variance, mean)
    }
}

public enum FaceAlignment {
    /// 両目中点の縦位置（上からの割合）。
    public static let eyeVerticalFromTop: CGFloat = 0.35
    /// 出力の辺 = 顔 bbox の長辺 × このスケール（従来の 30% マージン切り抜きと同等の画角）。
    public static let marginScale: CGFloat = 1.6
    /// この角度（45°）を超える傾きはランドマーク誤検出の可能性が高い → アライメントしない。
    public static let maxAngle: CGFloat = .pi / 4

    /// アライメント計画を作る。ランドマークが信用できない場合（目が同一点・過大な傾き・
    /// 顔が小さすぎる）は nil を返し、呼び出し側は従来の bbox 切り抜きへフォールバックする。
    /// - Parameters:
    ///   - leftEye/rightEye: 両目の中心（ピクセル・原点左下）。
    ///   - pixelBox: 顔 bbox（ピクセル・原点左下）。
    public static func plan(leftEye: CGPoint, rightEye: CGPoint, pixelBox: CGRect) -> FaceAlignmentPlan? {
        let dx = rightEye.x - leftEye.x
        let dy = rightEye.y - leftEye.y
        let eyeDistance = (dx * dx + dy * dy).squareRoot()
        guard eyeDistance >= 4 else { return nil }   // 目が近すぎ/同一点＝誤検出
        let side = max(pixelBox.width, pixelBox.height) * marginScale
        guard side >= 16 else { return nil }
        let angle = atan2(dy, dx)
        guard abs(angle) <= maxAngle else { return nil }
        let eyeMid = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
        let target = CGPoint(x: side * 0.5, y: side * (1 - eyeVerticalFromTop))
        return FaceAlignmentPlan(angle: angle, side: side, eyeMid: eyeMid, target: target)
    }
}
