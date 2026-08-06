import Foundation

/// 顔モデルの**類似度スケールに依存する定数一式**（ADR-70）。
///
/// AuraFace への換装計測で、しきい値・第2パス・統合候補帯域・監査の全定数が
/// **モデルの類似度分布に張り付いている**ことが分かった（AuraFace は同一人物の平均類似度が
/// facenet より約 0.1 低く、facenet 用定数のままだと F1 0.557 と*悪化して見えた*）。
/// 散らばった static を 1 つの値型に集約し、**同梱モデルの宣言（face_config.json の tuning）**で
/// プロファイルを選ぶ。モデルと定数がずれる事故（モデルだけ差し替え・アプリだけ更新）を防ぐ。
public struct FaceTuning: Sendable, Equatable {
    /// クラスタリング既定しきい値（校正の fallback でもある）。
    public var clusterThreshold: Float
    /// マージンゲート幅（ADR-57）。
    public var assignMargin: Float
    /// サイズ適応マージンの最大上乗せ（ADR-58）。
    public var sizeAdaptiveMarginMax: Float
    /// 第2パス（membership のみ・ADR-66）のしきい値。
    public var secondPassThreshold: Float
    /// サイズ免除の「競合が似ている」バー上乗せ（ADR-68）。
    public var rivalAlikeMargin: Float
    /// 統合候補の下限（ADR-68 追補2）。成長で離れた同一人物を拾い、兄弟平均は下回らない位置。
    public var mergeCandidateFloor: Float
    /// しきい値校正の可動域（ADR-46/68 追補）。
    public var calibrationRange: ClosedRange<Float>
    /// 負例判定の「ほぼ同じ人」しきい値（ADR-45）。
    public var negativeSameThreshold: Float
    /// 事後監査（ADR-69）の分離マージン下限／群間類似度上限。
    public var auditMinMargin: Float
    public var auditMaxSeparation: Float

    /// facenet（InceptionResnetV1/VGGFace2・v4 パイプライン）。
    /// 計測: face-accuracy.md 2026-08-01〜06（同一人物平均 0.550・FG-NET F1 0.664）。
    public static let facenet = FaceTuning(
        clusterThreshold: 0.50, assignMargin: 0.05, sizeAdaptiveMarginMax: 0.10,
        secondPassThreshold: 0.55, rivalAlikeMargin: 0.20, mergeCandidateFloor: 0.35,
        calibrationRange: 0.35...0.55, negativeSameThreshold: 0.55,
        auditMinMargin: 0.25, auditMaxSeparation: 0.35)

    /// ArcFace 系（AuraFace-v1・v5 パイプライン）。類似度スケールが約 0.1 低い
    /// （同一人物平均 0.434・別人 0.120・兄弟の代理 0.188）。
    /// 計測: face-accuracy.md 2026-08-06（FG-NET F1 0.790・LFW F1 0.892・家族 F1 1.000）。
    public static let arcFace = FaceTuning(
        clusterThreshold: 0.35, assignMargin: 0.04, sizeAdaptiveMarginMax: 0.08,
        secondPassThreshold: 0.40, rivalAlikeMargin: 0.20, mergeCandidateFloor: 0.25,
        calibrationRange: 0.25...0.40, negativeSameThreshold: 0.45,
        auditMinMargin: 0.20, auditMaxSeparation: 0.40)

    /// 実際に使う統合候補の下限（しきい値が低いときはそれに追従する・ADR-68 追補2）。
    public func mergeBandFloor(threshold: Float) -> Float {
        min(threshold - 0.10, mergeCandidateFloor)
    }

    /// 事後監査の設定（ADR-69）。メンバー下限は構造的な値なのでプロファイル共通。
    public var auditConfig: FaceClusterAudit.Config {
        FaceClusterAudit.Config(minMembers: 8, minGroupSize: 3,
                                minMargin: auditMinMargin, maxSeparation: auditMaxSeparation)
    }

    /// 宣言名から選ぶ（face_config.json の "tuning"）。未知・未指定は facenet（後方互換）。
    public static func named(_ name: String?) -> FaceTuning {
        switch name {
        case "arcface": return .arcFace
        default: return .facenet
        }
    }
}
