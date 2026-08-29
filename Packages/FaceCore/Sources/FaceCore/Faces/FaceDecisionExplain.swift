import Foundation

// MARK: - 「なぜ合流した / しなかった」を数字で説明する（ADR-135）
//
// ⚠️ チューニングの手掛かりは cos そのものではなく、**そこに何が上乗せされたか**にある。
// 実際、乗っ取り（ADR-130）も学習消失（ADR-134）も、効いていたのは類似度ではなく
// 「サイズ適応マージン」「種になれるか」「負例が効いているか」だった。近さの絵だけでは
// そこが見えないので、判定に使った値を**そのまま並べて見せる**。
//
// ここは純関数（SwiftData 非依存）。`FaceClustering.assign` と同じ順序・同じ式で判定する
// ——実装が変わったらこちらも変える必要があるが、**同じ規則を 2 回書かない**ために
// しきい値の合成は `FaceClustering.sizeMargin` を共用する。

/// 1 つの相手（人物）に対する判定の入力一式。
public struct FaceDecisionInputs: Sendable, Equatable {
    /// 手元の顔（または人物重心）と相手クラスタの類似度（重心とアンカーの最大＝assign と同じ）。
    public var similarity: Float
    /// 相手クラスタの重心寄与メンバー数（サイズ適応マージンの入力）。
    public var targetCount: Int
    /// 2 位の相手との類似度（マージンゲートの入力）。相手が 1 つだけなら nil。
    public var runnerUpSimilarity: Float?
    /// 負例（「この人ではない」の学習）が拒否するか。
    public var negativeRejected: Bool
    /// 同じ写真に一緒に写っている（同一写真 cannot-link ＝統合も合流も不可）。
    public var sharesPhoto: Bool
    /// 双方に**別々の名前**が付いている（ユーザーが既に「別人」と表明している）。
    public var nameConflict: Bool

    public init(similarity: Float, targetCount: Int, runnerUpSimilarity: Float? = nil,
                negativeRejected: Bool = false, sharesPhoto: Bool = false,
                nameConflict: Bool = false) {
        self.similarity = similarity
        self.targetCount = targetCount
        self.runnerUpSimilarity = runnerUpSimilarity
        self.negativeRejected = negativeRejected
        self.sharesPhoto = sharesPhoto
        self.nameConflict = nameConflict
    }
}

/// 判定に効くしきい値・マージンのスナップショット（表示と再現に使う）。
public struct FaceDecisionSettings: Sendable, Equatable {
    public var threshold: Float            // 校正後の合流しきい値
    public var baseThreshold: Float        // プロファイル既定（校正前）
    public var assignMargin: Float         // マージンゲート幅
    public var sizeAdaptiveMarginMax: Float
    public var matureCount: Int            // これ以上のメンバー数でサイズ上乗せ 0
    public var negativeSameThreshold: Float
    public var mergeBandFloor: Float       // 統合候補に出す下限

    public init(threshold: Float, baseThreshold: Float, assignMargin: Float,
                sizeAdaptiveMarginMax: Float, matureCount: Int,
                negativeSameThreshold: Float, mergeBandFloor: Float) {
        self.threshold = threshold
        self.baseThreshold = baseThreshold
        self.assignMargin = assignMargin
        self.sizeAdaptiveMarginMax = sizeAdaptiveMarginMax
        self.matureCount = matureCount
        self.negativeSameThreshold = negativeSameThreshold
        self.mergeBandFloor = mergeBandFloor
    }

    /// 相手のサイズに応じた上乗せ（`FaceClustering.sizeMargin` と同じ式）。
    public func sizeMargin(forCount count: Int) -> Float {
        guard sizeAdaptiveMarginMax > 0, count < matureCount else { return 0 }
        let mature = Float(max(2, matureCount))
        let frac = (mature - Float(count)) / (mature - 1)
        return max(0, min(1, frac)) * sizeAdaptiveMarginMax
    }

    /// 実効しきい値（この相手に入るために要る類似度）。
    public func requiredSimilarity(forCount count: Int) -> Float {
        threshold + sizeMargin(forCount: count)
    }
}

/// 判定の結論。**何が効いたか**が分かる粒度に分ける（「入らない」だけでは調整できない）。
public enum FaceDecisionVerdict: Sendable, Equatable {
    /// 合流する。
    case joins
    /// 同じ写真に一緒に写っている（別人と確定・合流も統合もしない）。
    case samePhoto
    /// 別々の名前が付いている（ユーザーが別人と表明済み）。
    case differentNames
    /// 1 位と 2 位が紛らわしい（差 < マージンゲート幅）。
    case blockedByMargin(gap: Float)
    /// 素のしきい値には届いているが、**相手が小さい**ぶんの上乗せで足りない。
    case blockedBySizeMargin(required: Float)
    /// しきい値そのものに届かない。
    case belowThreshold(required: Float)
    /// 「この人ではない」の学習（負例）が拒否した。
    case blockedByNegative
}

public enum FaceDecisionExplain {

    /// `FaceClustering.assign` と同じ順序で判定する。
    ///
    /// ⚠️ 順序が意味を持つ: マージンゲートは**除外・負例より先**（cannot-link された相手との
    /// 紛らわしさも「別人と紛らわしい」証拠として扱う）。ここでも同じ順に見る。
    public static func verdict(_ input: FaceDecisionInputs,
                               settings: FaceDecisionSettings) -> FaceDecisionVerdict {
        if input.nameConflict { return .differentNames }
        if input.sharesPhoto { return .samePhoto }
        let required = settings.requiredSimilarity(forCount: input.targetCount)
        if let runnerUp = input.runnerUpSimilarity, settings.assignMargin > 0,
           input.similarity >= settings.threshold, runnerUp >= settings.threshold,
           input.similarity - runnerUp < settings.assignMargin {
            return .blockedByMargin(gap: input.similarity - runnerUp)
        }
        if input.similarity < settings.threshold { return .belowThreshold(required: required) }
        if input.similarity < required { return .blockedBySizeMargin(required: required) }
        if input.negativeRejected { return .blockedByNegative }
        return .joins
    }
}
