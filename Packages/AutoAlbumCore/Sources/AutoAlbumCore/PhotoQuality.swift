import Foundation

/// 「きれいな写真（ベストショット）」判定のしきい値（ADR-78）。
///
/// スコアの出典は OS 内蔵の Vision 美的スコア（`VNCalculateImageAestheticsScoresRequest`・-1〜1）。
/// ブレ・露出・構図など複数要因の総合値で、夜間タグ付け（TagTagger）が全写真の台帳（TagsV1）に
/// 永続化している。外部モデル・通信は使わない（アプリ方針）。
public enum PhotoQuality {
    /// 「ベストショット」とみなす美的スコアの下限。
    /// 0.5 は「明確に良く撮れている」水準（スコアは -1〜1・大半の日常写真は 0 前後に集まる）。
    /// 体感で厳しすぎ/緩すぎが分かったらここを一元的に調整する（お気に入りを正解データにした
    /// AUC 校正も可能＝提案 B）。
    public static let beautifulThreshold: Double = 0.5
}
