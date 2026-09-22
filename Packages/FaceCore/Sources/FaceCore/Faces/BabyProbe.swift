import Accelerate
import Foundation

/// **赤ちゃん（0〜2 歳）判定**（ADR-219）。顔の埋め込みに対する線形判別器＝数値 513 個。
///
/// 追加の推論は要らない（顔の埋め込みは既にある）。判別器は埋め込みの空間に固有なので、
/// 顔モデルごとに学習し直す（`scripts/train_baby_probe.py`）。学習材料は FairFace
/// （CC BY 4.0・年齢区分「0〜2 歳」）。**画像はアプリに含まない**（数値だけ）。
///
/// ⚠️ しきい値は「赤ちゃんでない顔を赤ちゃんと取り違える率」を低く（1%）置く。取り違えた
/// 大人の顔どうしが「数年離れているので別人」とされると、同じ人が分かれるため。
public struct BabyProbe: Sendable, Equatable {
    public let weights: [Float]
    public let bias: Float
    public let threshold: Float

    public init(weights: [Float], bias: Float, threshold: Float) {
        self.weights = weights
        self.bias = bias
        self.threshold = threshold
    }

    /// - Parameter unit: 正規化済みの顔の埋め込み。
    public func score(_ unit: [Float]) -> Float {
        guard unit.count == weights.count else { return -.infinity }
        var s: Float = 0
        vDSP_dotpr(unit, 1, weights, 1, &s, vDSP_Length(unit.count))
        return s + bias
    }

    public func isBaby(_ unit: [Float]) -> Bool { score(unit) >= threshold }
}
