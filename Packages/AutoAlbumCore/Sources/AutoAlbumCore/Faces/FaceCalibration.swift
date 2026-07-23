import Foundation

/// 顔クラスタリングのしきい値をユーザー修正から**自動校正**する純ロジック（B1・ADR-46）。
///
/// 修正は「同一人物ペア（統合承認・顔の確認）」と「別人ペア（付け替え・統合拒否）」という
/// ラベル付きの類似度サンプルを生む。固定 0.45 の代わりに、正例と負例を最もよく分離する
/// しきい値を選ぶ＝ユーザーのライブラリの顔分布（家族の似方・撮影条件）に自動適応する。
/// サンプルが少ないうちは既定値のまま（過学習防止）。
public enum FaceCalibration {

    /// 既定しきい値（facenet 正規化埋め込みの手動調整値・校正前のフォールバック）。
    public static let defaultThreshold: Float = 0.45
    /// 校正に必要な最小サンプル数（正例・負例それぞれ）。未満なら既定値のまま。
    public static let minSamples = 8
    /// 校正結果の可動域（異常なサンプルでしきい値が暴れないための安全域）。
    public static let clampRange: ClosedRange<Float> = 0.35...0.60

    /// 正例（同一人物ペアの類似度）と負例（別人ペアの類似度）から最適しきい値を求める。
    /// 分類精度（正例 ≥ t かつ 負例 < t の数）を最大化する境界を選び、同点なら既定値に近い方。
    public static func calibratedThreshold(positive: [Float], negative: [Float],
                                           fallback: Float = defaultThreshold) -> Float {
        guard positive.count >= minSamples, negative.count >= minSamples else { return fallback }
        var best = fallback
        var bestScore = -1
        // 候補境界＝観測された全類似度（それ以外の値は分類結果が変わらない）。
        for t in Set(positive).union(negative) {
            let score = positive.filter { $0 >= t }.count + negative.filter { $0 < t }.count
            if score > bestScore
                || (score == bestScore && abs(t - fallback) < abs(best - fallback)) {
                best = t
                bestScore = score
            }
        }
        return min(max(best, clampRange.lowerBound), clampRange.upperBound)
    }
}
