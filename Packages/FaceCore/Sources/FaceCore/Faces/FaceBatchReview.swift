import Foundation

/// 一括レビュー（ADR-68）の 1 画面ぶん。
///
/// 従来の 1 対 1 カード（`FaceReviewItem.samePerson`）は **1 回答＝1 統合**なので、
/// 成長期の子供で数百〜数千に分裂したライブラリでは原理的に追いつかない。
/// そこで「基準の人物」に似たクラスタを**まとめて並べ**、違うものだけ外して一度に統合する。
///
/// ADR-56 で不採用にした**自動の連鎖統合とは別物**である点が重要:
/// 統合はすべてユーザーの確認を経る。確認のたびに基準クラスタが育ち、次の回で
/// さらに遠い時期のクラスタへ手が届く＝**人間が種を置く連鎖**になる。
public struct FaceBatchReviewItem: Sendable, Equatable {
    /// 基準となる人物（命名済みを優先し、なければ最大クラスタ）。
    public let anchorClusterID: Int
    public let anchorName: String
    public let anchorFace: PersonInfo.Face
    public let anchorCount: Int
    public let candidates: [Candidate]

    public struct Candidate: Sendable, Equatable, Identifiable {
        public let clusterID: Int
        public let face: PersonInfo.Face
        public let count: Int
        public let similarity: Float
        /// **あらかじめ選んでおく**か（似ている度が高く、ほぼ確実に同じ人・ADR-153）。
        /// 自動で結合はしない——ユーザーが外せる状態で見せる。
        public var preselected: Bool = false
        public var id: Int { clusterID }

        public init(clusterID: Int, face: PersonInfo.Face, count: Int, similarity: Float,
                    preselected: Bool = false) {
            self.clusterID = clusterID
            self.face = face
            self.count = count
            self.similarity = similarity
            self.preselected = preselected
        }
    }

    public init(anchorClusterID: Int, anchorName: String, anchorFace: PersonInfo.Face,
                anchorCount: Int, candidates: [Candidate]) {
        self.anchorClusterID = anchorClusterID
        self.anchorName = anchorName
        self.anchorFace = anchorFace
        self.anchorCount = anchorCount
        self.candidates = candidates
    }
}
