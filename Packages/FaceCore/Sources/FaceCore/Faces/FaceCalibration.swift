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
    ///
    /// ⚠️ 上限は 0.70 → **0.55**（ADR-68 追補）。実機で修正 130 件から校正値が **0.60** まで上がり、
    /// サイズ適応マージン（最大 +0.10）と積み上がって**実効 0.70**になっていた。0.70 は
    /// FG-NET で純度 0.907／再現率 0.342＝「混ざらないが全く集まらない」領域で、実測の
    /// 単発クラスタ 1,170 個・最大クラスタ 15 顔（9,446 枚スキャン）はこれで説明がつく。
    /// データセット計測: しきい値 0.60→0.55 で FG-NET 家族3人の分裂 5.0→2.3・F1 0.503→0.791、
    /// LFW（901人）は F1 0.904→0.906 でほぼ中立＝**両立する**。
    /// 校正そのものは維持する（ユーザーの修正は引き続き反映される）が、分裂側へ振り切らせない。
    public static let clampRange: ClosedRange<Float> = 0.35...0.55

    /// 正例（同一人物ペアの類似度）と負例（別人ペアの類似度）から最適しきい値を求める。
    /// 分類精度（正例 ≥ t かつ 負例 < t の数）を最大化する境界を選び、同点なら既定値に近い方。
    public static func calibratedThreshold(positive: [Float], negative: [Float],
                                           fallback: Float = defaultThreshold) -> Float {
        calibratedThreshold(positive: positive.map { ($0, 1) },
                            negative: negative.map { ($0, 1) }, fallback: fallback)
    }

    /// **確度で重み付けした**校正（ADR-68 追補6）。
    ///
    /// 同じ「はい」でも判断材料の量で信頼度は違う。1 対 1 の確認（2 枚を並べて尋ねる）は
    /// 材料が揃っているが、まとめて確認（小さなアバターを一覧から選ぶ）は取り違えが起こりやすく、
    /// **1 セッションで数百件入る**ため、等重みだと校正がそれ一色に染まる（実機で修正 216→611 件の
    /// 大半が一括レビュー由来だった）。件数ではなく**重みの合計**で最適境界を選ぶ。
    ///
    /// - Parameters:
    ///   - positive/negative: (類似度, 重み) の並び。重みは `FaceCorrection.confidence`。
    public static func calibratedThreshold(positive: [(Float, Double)],
                                           negative: [(Float, Double)],
                                           fallback: Float = defaultThreshold) -> Float {
        // サンプル数の足切りは**重み合計**で見る（低確度ばかりで校正を動かさない）。
        let posWeight = positive.reduce(0.0) { $0 + $1.1 }
        let negWeight = negative.reduce(0.0) { $0 + $1.1 }
        guard posWeight >= Double(minSamples), negWeight >= Double(minSamples) else { return fallback }
        var best = fallback
        var bestScore = -Double.greatestFiniteMagnitude
        // 候補境界＝観測された全類似度（それ以外の値は分類結果が変わらない）。
        for t in Set(positive.map(\.0)).union(negative.map(\.0)) {
            let score = positive.filter { $0.0 >= t }.reduce(0.0) { $0 + $1.1 }
                + negative.filter { $0.0 < t }.reduce(0.0) { $0 + $1.1 }
            if score > bestScore
                || (score == bestScore && abs(t - fallback) < abs(best - fallback)) {
                best = t
                bestScore = score
            }
        }
        return min(max(best, clampRange.lowerBound), clampRange.upperBound)
    }
}
