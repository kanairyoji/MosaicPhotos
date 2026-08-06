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
    /// クラスタの**境界**にいる顔の確認（A2・混入の検出）。
    /// - `name` が非 nil（命名済み）:「この写真は「◯◯」さんですか？」
    /// - `name` が nil（未命名）: 名前を出しても答えられないため、代表の顔（`coverFace`）と
    ///   並べて「この 2 枚は同じ人物ですか？」という**見た目だけで判断できる**カードにする。
    /// はい → 確認済み（アンカー＋正例）。いいえ → 分離（負例）。
    case isThisPerson(face: PersonInfo.Face, clusterID: Int, name: String?,
                      coverFace: PersonInfo.Face, similarity: Float)

    /// **1 人物の中に 2 つの塊がある**（A3・ADR-69）。統合した後に写真が増えて、
    /// 「実は兄弟が混ざっていた」と分かるケースを拾う事後監査。
    /// はい（同じ人）→ 以後この対は尋ねない。いいえ（別人）→ **クラスタを 2 つに分割**。
    case splitCluster(clusterID: Int, name: String?,
                      faceA: PersonInfo.Face, faceB: PersonInfo.Face,
                      groupBFaceIDs: [String], margin: Float)

    public var id: String {
        switch self {
        case .samePerson(let a, _, _, let b, _, _, _): return "same|\(a)|\(b)"
        case .isThisPerson(let face, let c, _, _, _):   return "confirm|\(face.faceID)|\(c)"
        case .splitCluster(let c, _, let a, let b, _, _): return "split|\(c)|\(a.faceID)|\(b.faceID)"
        }
    }
}
