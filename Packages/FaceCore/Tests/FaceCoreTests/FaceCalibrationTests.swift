import Foundation
import Testing
@testable import FaceCore

/// しきい値の自動校正（B1・ADR-46）の純ロジック。
@Suite("FaceCalibration (threshold from corrections)")
struct FaceCalibrationTests {

    @Test("サンプル不足なら既定値のまま（過学習防止）")
    func fallbackWhenFewSamples() {
        let t = FaceCalibration.calibratedThreshold(positive: [0.6, 0.7], negative: [0.3])
        #expect(t == FaceCalibration.defaultThreshold)
    }

    @Test("正例と負例を最もよく分離する境界を選ぶ")
    func separatesPositiveNegative() {
        // 正例（同一人物）は 0.50 以上、負例（別人）は 0.42 以下に分布 → 境界は 0.50 付近。
        let positive: [Float] = [0.50, 0.52, 0.55, 0.58, 0.60, 0.62, 0.65, 0.70]
        let negative: [Float] = [0.30, 0.32, 0.35, 0.36, 0.38, 0.40, 0.41, 0.42]
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative)
        #expect(t > 0.42)
        #expect(t <= 0.50)
        // 完全分離＝全サンプル正解
        #expect(positive.allSatisfy { $0 >= t })
        #expect(negative.allSatisfy { $0 < t })
    }

    @Test("外れサンプルでもクランプ域を出ない")
    func clamped() {
        // 正例が異常に低い分布（0.2 台）→ そのまま選ぶと 0.2 だがクランプ下限で止まる。
        let positive: [Float] = [0.20, 0.21, 0.22, 0.23, 0.24, 0.25, 0.26, 0.27]
        let negative: [Float] = [0.05, 0.06, 0.07, 0.08, 0.09, 0.10, 0.11, 0.12]
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative)
        #expect(t >= FaceCalibration.clampRange.lowerBound)
        #expect(t <= FaceCalibration.clampRange.upperBound)
    }

    @Test("分布が重なるときは誤分類最小の境界を選ぶ")
    func overlappingDistributions() {
        let positive: [Float] = [0.45, 0.48, 0.50, 0.52, 0.55, 0.58, 0.60, 0.42]  // 1 個だけ低い
        let negative: [Float] = [0.30, 0.33, 0.35, 0.38, 0.40, 0.43, 0.46, 0.36]  // 1 個だけ高い
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative)
        // 誤分類は最大 2（低い正例と高い負例）に収まる境界のはず。
        let errors = positive.filter { $0 < t }.count + negative.filter { $0 >= t }.count
        #expect(errors <= 2)
    }

    @Test("確度で重み付けする: 低確度の回答が多数でも高確度の少数を押し流さない")
    func weightedCalibration() {
        // 高確度（1 対 1 の確認）: 同一人物 0.52 / 別人 0.48 → 境界は 0.52 付近が正しい。
        let highPos = Array(repeating: (Float(0.52), 1.0), count: 10)
        let highNeg = Array(repeating: (Float(0.48), 1.0), count: 10)
        // 低確度（まとめて確認）: 取り違えを含み「同じ人」と答えた類似度が低めに偏る。
        // 件数は多い（1 セッションで数百件入る実態）が、重みは 0.4。
        let batchPos = Array(repeating: (Float(0.36), 0.4), count: 20)

        let weighted = FaceCalibration.calibratedThreshold(
            positive: highPos + batchPos, negative: highNeg, fallback: 0.50)
        let unweighted = FaceCalibration.calibratedThreshold(
            positive: (highPos + batchPos).map { ($0.0, 1.0) },
            negative: highNeg.map { ($0.0, 1.0) }, fallback: 0.50)
        // 等重みだと件数の多い低確度サンプルに引きずられ、境界が 0.36 まで落ちる。
        #expect(abs(unweighted - 0.36) < 1e-5)
        // 重み付けなら高確度側の境界（0.52）が残る。
        #expect(abs(weighted - 0.52) < 1e-5)
    }

    @Test("重み合計が最小サンプル数に満たなければ校正しない")
    func weightedMinimumSamples() {
        // 低確度（0.4）×10 件 = 重み 4.0 < minSamples(8) → 既定値のまま。
        let pos = Array(repeating: (Float(0.6), 0.4), count: 10)
        let neg = Array(repeating: (Float(0.2), 0.4), count: 10)
        #expect(FaceCalibration.calibratedThreshold(positive: pos, negative: neg,
                                                    fallback: 0.50) == 0.50)
    }
}
