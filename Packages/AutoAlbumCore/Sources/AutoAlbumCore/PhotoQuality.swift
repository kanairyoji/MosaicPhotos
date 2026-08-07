import Foundation

/// 「きれいな写真（ベストショット）」判定（ADR-78）。
///
/// スコアの出典は OS 内蔵の Vision 美的スコア（`VNCalculateImageAestheticsScoresRequest`・-1〜1）。
/// ブレ・露出・構図など複数要因の総合値で、夜間タグ付け（TagTagger）が全写真の台帳（TagsV1）に
/// 永続化している。外部モデル・通信は使わない（アプリ方針）。
///
/// しきい値は**分布適応**（ADR-78 追記）: Vision スコアは日常写真だと 0 前後に集まり、固定 0.5 では
/// ほぼ全滅する（実障害）。「そのライブラリの上位 `topFraction`」を基本に、絶対範囲
/// [`thresholdFloor`, `thresholdCeiling`] へクランプして「上位だが客観的にも悪くない」水準を保つ。
public enum PhotoQuality {
    /// ベストショットとみなす割合（スコア付き写真の上位 20%）。
    public static let topFraction = 0.2
    /// しきい値の下限。ライブラリ全体のスコアが低くても、これ未満を「ベスト」とは呼ばない。
    public static let thresholdFloor = 0.2
    /// しきい値の上限。粒ぞろいのライブラリでは 20% より多く通す（良い写真を落とさない）。
    public static let thresholdCeiling = 0.6

    /// スコア一覧から適応しきい値を決める（純・テスト対象）。空なら上限（＝何も通さない側）。
    /// 「このしきい値以上が約 topFraction」になる境界値＝降順ソートの `count*topFraction` 番目
    /// の**1 つ手前**（0 始まり）。件数が少なければ最高スコアのみ。
    public static func adaptiveThreshold(scores: [Double]) -> Double {
        guard !scores.isEmpty else { return thresholdCeiling }
        let sorted = scores.sorted(by: >)
        let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * topFraction) - 1))
        return min(max(sorted[idx], thresholdFloor), thresholdCeiling)
    }
}
