import Foundation

/// 顔モデルの**類似度スケールに依存する定数一式**（ADR-70）。
///
/// AuraFace への換装計測で、しきい値・第2パス・統合候補帯域・監査の全定数が
/// **モデルの類似度分布に張り付いている**ことが分かった（AuraFace は同一人物の平均類似度が
/// facenet より約 0.1 低く、facenet 用定数のままだと F1 0.557 と*悪化して見えた*）。
/// 散らばった static を 1 つの値型に集約し、**同梱モデルの宣言（face_config.json の tuning）**で
/// プロファイルを選ぶ。モデルと定数がずれる事故（モデルだけ差し替え・アプリだけ更新）を防ぐ。
public struct FaceTuning: Sendable, Equatable {
    /// プロファイル名（修正ジャーナルのスケールタグにも使う・ADR-70 追補）。
    public var name: String
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
    /// 「同じ人ですか？」と**尋ねる**下限（ADR-150）。低すぎると当たらない対ばかり出す。
    public var mergeCandidateFloor: Float
    /// **断片を自動で吸収する**バー（ADR-154）。1〜2 枚の無名クラスタを、確立した人物へ
    /// 機械的に寄せてよい近さ。事前選択（`autoSuggestBar`）より低くできるのは、
    /// **失敗の代償が小さい**から——断片 1〜2 枚が入っても大きな人物の重心は動かず、
    /// 間違いは 1 枚外すだけで直る（人物どうしの結合は取り返しが付かないので自動化しない）。
    public var autoAbsorbBar: Float

    /// **あらかじめ選んでおく**（まとめて確認）バー（ADR-153）。
    ///
    /// ⚠️ 自動で結合するのではなく、**チェックを付けた状態で見せる**ための値。実機 7,710 件の
    /// 「同じ人」回答のうち 18% がこの値以上で、その帯での正しさは 98%（ユーザー自身が
    /// 「別人」と答えた対だけで見れば 99.9%）。ただし家族ライブラリでは 0.885/0.920 の対を
    /// 「別人」と答えた実例もあるため、**黙って結合はしない**。
    public var autoSuggestBar: Float

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
        name: "facenet",
        clusterThreshold: 0.50, assignMargin: 0.05, sizeAdaptiveMarginMax: 0.10,
        secondPassThreshold: 0.55, rivalAlikeMargin: 0.20, mergeCandidateFloor: 0.50,
        autoAbsorbBar: 0.80, autoSuggestBar: 0.90,
        calibrationRange: 0.35...0.55, negativeSameThreshold: 0.55,
        auditMinMargin: 0.25, auditMaxSeparation: 0.35)

    /// ArcFace 系（AuraFace-v1・v5 パイプライン）。類似度スケールが約 0.1 低い
    /// （同一人物平均 0.434・別人 0.120・兄弟の代理 0.188）。
    /// 計測: face-accuracy.md 2026-08-06（FG-NET F1 0.790・LFW F1 0.892・家族 F1 1.000）。
    public static let arcFace = FaceTuning(
        name: "arcface",
        clusterThreshold: 0.35, assignMargin: 0.04, sizeAdaptiveMarginMax: 0.08,
        secondPassThreshold: 0.40, rivalAlikeMargin: 0.20, mergeCandidateFloor: 0.40,
        autoAbsorbBar: 0.75, autoSuggestBar: 0.85,
        calibrationRange: 0.25...0.40, negativeSameThreshold: 0.45,
        auditMinMargin: 0.20, auditMaxSeparation: 0.40)

    /// 実際に使う「尋ねる」下限。
    ///
    /// ⚠️ 以前は `min(threshold - 0.10, floor)` で**しきい値より下**へ降りていた（arcface で 0.25）。
    /// FG-NET 実測（本番設定）では 0.25 の当たり率は **4.3%**——96% が「まず yes にならない対」で、
    /// レビューの質も候補生成の速度も損ねていた（0.40 なら当たり率 14.3%・尋ねる数は 1/7）。
    /// 実機のユーザー回答でも「同じ人」と答えた対は**下位 5% で 0.669**＝この引き上げで
    /// 失う当たりはほぼ無い。しきい値が校正で上がったときは、そちらに合わせる（ADR-150）。
    public func mergeBandFloor(threshold: Float) -> Float {
        max(mergeCandidateFloor, threshold)
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
