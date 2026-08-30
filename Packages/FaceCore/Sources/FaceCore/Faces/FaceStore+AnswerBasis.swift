import Foundation
import PerceptionCore
import SwiftData

// MARK: - あなたの回答から見た基準（ADR-148・Step 1）

/// 片側（「同じ人」または「別人」と答えた回答）の類似度分布。
public struct AnswerSimilaritySide: Sendable, Equatable {
    public let count: Int
    public let median: Float
    public let p10: Float
    public let p90: Float
    /// 10% 刻みのヒストグラム（0–10%, 10–20%, …, 90–100%）。
    public let histogram: [Int]
}

/// ユーザーの回答（修正ジャーナル）から見た「同じ人／別人」の分かれ方。
///
/// ⚠️ **感覚ではなく自分のデータで決める**ための材料（ADR-148）。しきい値の議論は
/// 「厳しすぎる気がする」で動かすと、直すほど別の壊れ方をする（ADR-140/141 で経験した）。
/// あなたが実際に「同じ人」「別人」と答えたペアの類似度がどう分かれているかを出せば、
/// **あなたの写真における適正な境界**がそのまま読める。
public struct AnswerSimilarityProfile: Sendable, Equatable {
    /// 何と何の類似度か（人物どうし＝重心×重心／顔と人物＝顔×重心）。尺度が違うので混ぜない。
    public enum Kind: Sendable, Equatable {
        case personPair    // merge / notSame
        case faceToPerson  // confirm・sameGroup / reassign
    }
    public let kind: Kind
    public let same: AnswerSimilaritySide
    public let different: AnswerSimilaritySide
    /// 2 つを最もよく分ける境界（十分な回答数があるときだけ）。
    public let bestBar: Float?
    /// その境界での取りこぼし（同じ人なのに境界未満）と取り違え（別人なのに境界以上）。
    public let sameBelowBar: Int
    public let differentAboveBar: Int
    /// 分布がどれだけ離れているか（同じ人の中央値 − 別人の中央値）。大きいほど決めやすい。
    public var separation: Float { same.median - different.median }
}

extension FaceStore {

    /// 十分な回答数（これ未満なら境界は出さない＝少数の回答で基準を動かさない）。
    static let answerBasisMinSamples = 8

    /// 修正ジャーナルから「あなたの回答の分かれ方」を作る（読み取り専用）。
    func answerSimilarityProfile(kind: AnswerSimilarityProfile.Kind) -> AnswerSimilarityProfile {
        let rows = (countedFetchOptional(FetchDescriptor<FaceCorrection>())) ?? []
        var same: [Float] = []
        var different: [Float] = []
        for row in rows {
            // ⚠️ 別モデル世代の行は混ぜない（類似度はモデルの空間に張り付いている・ADR-70）。
            guard (row.profile ?? "facenet") == tuning.name, let sim = row.similarity else { continue }
            switch (kind, row.kind) {
            case (.personPair, "merge"), (.faceToPerson, "confirm"), (.faceToPerson, "sameGroup"):
                same.append(Float(sim))
            case (.personPair, "notSame"), (.faceToPerson, "reassign"):
                different.append(Float(sim))
            default: continue
            }
        }
        let bar: Float? = (same.count >= Self.answerBasisMinSamples
                           && different.count >= Self.answerBasisMinSamples)
            ? FaceCalibration.calibratedThreshold(positive: same.map { ($0, 1.0) },
                                                  negative: different.map { ($0, 1.0) },
                                                  fallback: tuning.clusterThreshold,
                                                  clamp: 0...1)
            : nil
        return AnswerSimilarityProfile(
            kind: kind,
            same: FaceStore.summarize(same),
            different: FaceStore.summarize(different),
            bestBar: bar,
            sameBelowBar: bar.map { b in same.filter { $0 < b }.count } ?? 0,
            differentAboveBar: bar.map { b in different.filter { $0 >= b }.count } ?? 0)
    }

    /// いま効いている基準（校正後・既定・尋ねる候補の下限）。
    func currentThresholds() -> (calibrated: Float, base: Float, askBar: Float) {
        let calibrated = calibratedThreshold()
        return (calibrated, tuning.clusterThreshold, tuning.mergeBandFloor(threshold: calibrated))
    }

    /// 分布の要約（純・テスト対象）。
    static func summarize(_ values: [Float]) -> AnswerSimilaritySide {
        guard !values.isEmpty else {
            return AnswerSimilaritySide(count: 0, median: 0, p10: 0, p90: 0,
                                        histogram: Array(repeating: 0, count: 10))
        }
        let sorted = values.sorted()
        func at(_ p: Double) -> Float {
            let index = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[max(0, min(sorted.count - 1, index))]
        }
        var histogram = Array(repeating: 0, count: 10)
        for value in values {
            let bucket = min(9, max(0, Int((value * 10).rounded(.down))))
            histogram[bucket] += 1
        }
        return AnswerSimilaritySide(count: values.count, median: at(0.5),
                                    p10: at(0.1), p90: at(0.9), histogram: histogram)
    }
}

extension FaceStore {
    /// テスト用: 修正ジャーナルへ 1 件書く（種類と類似度だけを指定する）。
    func recordCorrectionForTesting(kind: String, similarity: Float) {
        let zero = ClipMath.encodeHalf([1, 0, 0])
        recordCorrection(kind: kind, faceEmbedding: zero, wrongEmbedding: zero, similarity: similarity)
        try? modelContext.save()
    }
}
