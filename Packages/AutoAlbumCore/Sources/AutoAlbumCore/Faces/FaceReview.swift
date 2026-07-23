import Foundation

/// 人物レビュー（ADR-46・A1/A2）の 1 カード。
/// iPhone の写真アプリの「この人は◯◯さんですか？」に相当する**アクティブラーニング**：
/// 判断が最も割れる（＝学習価値の高い）ケースだけをユーザーに尋ね、回答を
/// 正例/負例・アンカー・しきい値校正の材料にする。
public enum FaceReviewItem: Sendable, Identifiable, Equatable {
    /// 「同じ人物ですか？」— 統合の一歩手前の類似度を持つ 2 クラスタ（A1・過分割の修復）。
    /// はい → 統合（正例）。いいえ → 「別人」記録（負例・以後は提案しない＆合流を拒否）。
    case samePerson(aClusterID: Int, aName: String, aFace: PersonInfo.Face,
                    bClusterID: Int, bName: String, bFace: PersonInfo.Face,
                    similarity: Float)
    /// 「この写真は「◯◯」さんですか？」— クラスタの**境界**にいる顔の確認（A2・混入の検出）。
    /// はい → 確認済み（アンカー＋正例）。いいえ → 分離（負例）。
    case isThisPerson(face: PersonInfo.Face, clusterID: Int, name: String,
                      similarity: Float)

    public var id: String {
        switch self {
        case .samePerson(let a, _, _, let b, _, _, _): return "same|\(a)|\(b)"
        case .isThisPerson(let face, let c, _, _):      return "confirm|\(face.faceID)|\(c)"
        }
    }
}
