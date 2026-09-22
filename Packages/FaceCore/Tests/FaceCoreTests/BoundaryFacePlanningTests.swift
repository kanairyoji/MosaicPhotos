import Testing
@testable import FaceCore

/// A2 境界の顔の選び方（`ReviewCandidatePlanning.boundaryFaces`）。
@Suite("境界の顔の選び方")
struct BoundaryFacePlanningTests {

    private let candidates: [(faceID: String, similarity: Float)] = [
        ("a", 0.30), ("b", 0.50), ("c", 0.20), ("d", 0.44), ("e", 0.10),
    ]

    @Test("帯（しきい値＋0.10）未満の顔だけを、類似の低い順に 2 枚まで")
    func picksLowestUnderBand() {
        let picks = ReviewCandidatePlanning.boundaryFaces(candidates, threshold: 0.35,
                                                          skipFaceID: nil, isExcluded: { _ in false })
        #expect(picks.map(\.faceID) == ["e", "c"])
    }

    @Test("無名の人物の代表顔は飛ばし、次点で埋める")
    func skipsCoverFace() {
        let picks = ReviewCandidatePlanning.boundaryFaces(candidates, threshold: 0.35,
                                                          skipFaceID: "e", isExcluded: { _ in false })
        #expect(picks.map(\.faceID) == ["c", "a"])
    }

    @Test("出題済みは飛ばし、次点で埋める")
    func skipsExcluded() {
        let picks = ReviewCandidatePlanning.boundaryFaces(candidates, threshold: 0.35,
                                                          skipFaceID: nil, isExcluded: { $0 == "c" })
        #expect(picks.map(\.faceID) == ["e", "a"])
    }

    @Test("帯に入る顔が無ければ何も出さない（0.45 の顔は帯の外）")
    func nothingWhenAllAboveBand() {
        let picks = ReviewCandidatePlanning.boundaryFaces([("x", 0.45), ("y", 0.9)], threshold: 0.35,
                                                          skipFaceID: nil, isExcluded: { _ in false })
        #expect(picks.isEmpty)
    }

    @Test("同じ類似なら faceID 順（実行ごとに揺れない）")
    func tiesAreDeterministic() {
        let picks = ReviewCandidatePlanning.boundaryFaces([("q", 0.1), ("p", 0.1), ("r", 0.1)],
                                                          threshold: 0.35, skipFaceID: nil,
                                                          isExcluded: { _ in false })
        #expect(picks.map(\.faceID) == ["p", "q"])
    }
}
