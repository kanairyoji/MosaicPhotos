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
}
