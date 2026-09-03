import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 版上げ後の名前の持ち越し（ADR-169）。純ロジックの一対一対応。
///
/// ⚠️ 旧実装は旧人物ごとに「重なり最大」を貪欲に取っていた。局所的な最良ペアが
/// **別の旧人物にとって唯一の対応先**を奪うと、存在する一対一対応を見逃して名前が戻らない。
@Suite("名前の持ち越し（一対一対応）")
struct NameCarryoverMatchingTests {

    @Test("唯一の対応先を奪わない（貪欲だと片方が戻らない）")
    func doesNotStealTheOnlyCandidate() {
        // A は X(5) と Y(4) に対応でき、B は X(3) しか無い。
        // 貪欲: A→X を取ると B は行き先を失う。正解は A→Y, B→X。
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 5, 2: 4]),
            .init(name: "B", candidates: [1: 3]),
        ])
        #expect(unmatched.isEmpty, "両方戻せるはずなのに片方が未確定: \(unmatched)")
        #expect(assignments[0] == 2 && assignments[1] == 1,
                "唯一の候補を奪っている: \(assignments)")
    }

    /// この不具合の本体。**同名の別人**（"太郎" が 2 人）が別々の人物へ戻ること。
    @Test("同名の別人でも、それぞれ別の人物へ戻る")
    func sameNameDifferentPeople() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "太郎", candidates: [10: 8]),
            .init(name: "太郎", candidates: [11: 6]),
        ])
        #expect(unmatched.isEmpty, "同名を理由に片方が捨てられている")
        #expect(assignments[0] == 10 && assignments[1] == 11)
        #expect(Set(assignments.values).count == 2, "2 人が同じクラスタへ割り当てられている")
    }

    @Test("1 つの人物へ 2 つの名前は割り当てない")
    func oneClusterOneName() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 9]),
            .init(name: "B", candidates: [1: 8]),
        ])
        #expect(assignments.count == 1, "同じクラスタに 2 つ割り当てている: \(assignments)")
        #expect(unmatched.count == 1, "行き先の無いエントリが残りに入っていない")
    }

    @Test("候補が無いエントリは残りに入る（黙って消えない）")
    func noCandidateIsKept() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [:]),
        ])
        #expect(assignments.isEmpty)
        #expect(unmatched == [0], "候補ゼロのエントリが失われている")
    }

    @Test("同数を戻せるなら重なりの大きい対を選ぶ")
    func prefersLargerOverlapWhenTied() {
        let (assignments, _) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 2, 2: 9]),
        ])
        #expect(assignments[0] == 2, "重なりの小さい方を選んでいる")
    }

    @Test("空入力は空を返す")
    func emptyInput() {
        let (assignments, unmatched) = NameCarryoverMatching.match([])
        #expect(assignments.isEmpty && unmatched.isEmpty)
    }
}

/// ストア越しの振る舞い（`reapplyNames`）。
@Suite("名前の持ち越し（ストア）", .serialized)
struct NameCarryoverStoreTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// ⚠️ **同名の別人**を作って、2 人目の名前が消えないことを見る。
    /// 旧実装は「同名クラスタが既にある」だけで `continue` し、残りにも積まなかったため、
    /// 2 人目の名前と旧メンバーの対応が永久に失われていた。
    @Test("同名の別人でも 2 人目の名前が失われない")
    func sameNameSurvives() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<4 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        #expect(map.count >= 2, "fixture: 2 クラスタになっていない")

        // 旧版で「太郎」が 2 人いた状態の持ち越し（メンバーは今のクラスタと重なる）。
        let entries: [(name: String, memberRefKeys: [String])] = [
            ("太郎", ["L-a0", "L-a1", "L-a2", "L-a3"]),
            ("太郎", ["L-b0", "L-b1", "L-b2", "L-b3"]),
        ]
        let remaining = await store.reapplyNames(entries)
        #expect(remaining.isEmpty, "戻せるはずの名前が残っている: \(remaining.count)")

        let named = await store.allClusters().filter { $0.name == "太郎" }
        #expect(named.count == 2, "同名の別人が 2 人とも命名されていない（\(named.count) 人）")
    }

    @Test("対応先が無い名前は残りとして返る（次回に再評価できる）")
    func unmatchedIsReturned() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        // どの写真とも重ならない持ち越し。
        let remaining = await store.reapplyNames([("花子", ["L-zz0", "L-zz1", "L-zz2"])])
        #expect(remaining.count == 1, "行き先の無い名前が黙って消えている")
        #expect(remaining.first?.name == "花子")
        #expect(remaining.first?.memberRefKeys.count == 3, "旧メンバーの対応まで失っている")
    }
}
