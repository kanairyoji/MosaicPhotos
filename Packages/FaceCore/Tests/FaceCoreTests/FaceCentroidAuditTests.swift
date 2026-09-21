import PerceptionCore
import Foundation
import Testing
@testable import FaceCore

/// 重心（sum/count）の整合検査（ADR-210）。
///
/// ⚠️ ここが緩いと、**監査そのものが嘘をつく**（正しい重心を壊れていると言い、
/// 直しに行って壊す）。式が本体（`FaceClustering.adding`）と同じであることを含めて固定する。
@Suite("重心の整合検査（ADR-210）")
struct FaceCentroidAuditTests {

    private func vector(_ seed: Int, dim: Int = 8) -> [Float] {
        (0..<dim).map { Float(($0 * 7 + seed * 13) % 11) / 11.0 + (($0 == seed % dim) ? 1.0 : 0.0) }
    }

    private func member(_ id: String, quality: Float = 0.8,
                        contributes: Bool = true) -> FaceCentroidAudit.Member {
        .init(faceID: id, quality: quality, contributes: contributes)
    }

    /// 寄与メンバーから作った sum/count を「正しい記録」として組み立てる。
    private func healthy(_ ids: [String], clusterID: Int = 1,
                         quality: Float = 0.8) -> (FaceCentroidAudit.ClusterState, [String: [Float]]) {
        var embeddings: [String: [Float]] = [:]
        for (index, id) in ids.enumerated() { embeddings[id] = vector(index + 1) }
        var sum: [Float] = [Float](repeating: 0, count: 8)
        var count = 0
        for id in ids {
            let added = FaceClustering.adding(embeddings[id]!, toSum: sum, count: count,
                                              quality: quality)
            sum = added.sum
            count = added.count
        }
        let state = FaceCentroidAudit.ClusterState(
            clusterID: clusterID, storedSum: sum, storedCount: count,
            members: ids.map { member($0, quality: quality) })
        return (state, embeddings)
    }

    @Test("整合している人物は何も報告しない")
    func healthyClusterIsSilent() {
        let (state, embeddings) = healthy(["a", "b", "c"])
        #expect(FaceCentroidAudit.check(clusters: [state], embedding: { embeddings[$0] }).isEmpty)
    }

    /// 実際に踏んだ形（`unresolved-problems.md`）: 行は「寄与した」と言うのに sum は
    /// 品質フロア以上の顔だけで作られていた。件数の食い違いとして必ず見える。
    @Test("行が『寄与した』と言う数と count が合わなければ報告する")
    func countMismatchIsReported() {
        var (state, embeddings) = healthy(["a", "b", "c"])
        // 実際の sum は 3 枚ぶんなのに、記録された count だけが 1（＝寄与を数え漏らした状態）。
        state = FaceCentroidAudit.ClusterState(clusterID: state.clusterID,
                                               storedSum: state.storedSum, storedCount: 1,
                                               members: state.members)
        let findings = FaceCentroidAudit.check(clusters: [state], embedding: { embeddings[$0] })
        #expect(findings.count == 1)
        #expect(findings[0].kind == .countMismatch)
        #expect(findings[0].storedCount == 1)
        #expect(findings[0].expectedCount == 3)
    }

    @Test("件数が合っていても向きがずれていれば報告する")
    func driftIsReported() {
        let (state, embeddings) = healthy(["a", "b", "c"])
        // 別人の方向へ引きずられた重心（件数はそのまま）。
        let drifted = FaceCentroidAudit.ClusterState(
            clusterID: state.clusterID, storedSum: vector(42).map { $0 * 3 },
            storedCount: state.storedCount, members: state.members)
        let findings = FaceCentroidAudit.check(clusters: [drifted], embedding: { embeddings[$0] })
        #expect(findings.count == 1)
        #expect(findings[0].kind == .sumDrift)
        #expect(findings[0].alignment < FaceCentroidAudit.minAlignment)
    }

    @Test("寄与メンバーが居るのに sum が零なら報告する（誰も合流できない人物）")
    func emptyCentroidIsReported() {
        let (state, embeddings) = healthy(["a", "b"])
        let empty = FaceCentroidAudit.ClusterState(
            clusterID: state.clusterID, storedSum: [Float](repeating: 0, count: 8),
            storedCount: state.storedCount, members: state.members)
        let findings = FaceCentroidAudit.check(clusters: [empty], embedding: { embeddings[$0] })
        #expect(findings.map(\.kind) == [.emptyCentroid])
    }

    /// 全員が低品質などで寄与が 0 の人物は、同一性を保つために向きだけ残してある。
    /// 作り物と分かっているものを毎晩挙げると、本物のずれが埋もれる。
    @Test("寄与 0 の『同一性を保つためだけの種』は食い違いとして数えない")
    func syntheticSeedIsExempt() {
        let state = FaceCentroidAudit.ClusterState(
            clusterID: 1, storedSum: vector(1), storedCount: 1,
            members: [member("a", quality: 0.1, contributes: false)])
        #expect(FaceCentroidAudit.check(clusters: [state], embedding: { _ in self.vector(1) }).isEmpty)
        // ただし 2 以上を名乗っていたら、それは作り物では説明が付かない。
        let lying = FaceCentroidAudit.ClusterState(
            clusterID: 1, storedSum: vector(1), storedCount: 5, members: state.members)
        #expect(FaceCentroidAudit.check(clusters: [lying], embedding: { _ in self.vector(1) })
                    .map(\.kind) == [.countMismatch])
    }

    @Test("Float16 に丸めた程度のずれは正常とみなす（量子化で毎晩鳴らない）")
    func quantisationIsTolerated() {
        let (state, embeddings) = healthy(["a", "b", "c", "d"])
        let rounded = ClipMath.decodeHalf(ClipMath.encodeHalf(state.storedSum))!
        let quantised = FaceCentroidAudit.ClusterState(
            clusterID: state.clusterID, storedSum: rounded,
            storedCount: state.storedCount, members: state.members)
        #expect(FaceCentroidAudit.check(clusters: [quantised], embedding: { embeddings[$0] }).isEmpty)
    }

    @Test("報告はクラスタ ID 順で決定的（同じ台帳からは同じ並び）")
    func findingsAreDeterministic() {
        var states: [FaceCentroidAudit.ClusterState] = []
        var all: [String: [Float]] = [:]
        for id in [5, 2, 9, 1] {
            let (state, embeddings) = healthy(["a\(id)", "b\(id)"], clusterID: id)
            states.append(.init(clusterID: id, storedSum: state.storedSum, storedCount: 99,
                                members: state.members))
            all.merge(embeddings) { a, _ in a }
        }
        let findings = FaceCentroidAudit.check(clusters: states, embedding: { all[$0] })
        #expect(findings.map(\.clusterID) == [1, 2, 5, 9])
    }

    /// ⚠️ **監査の式が本体とずれていたら意味がない**。`adding` を 1 枚ずつ回した結果と
    /// `expected` が完全一致することを固定する。
    @Test("expected は FaceClustering.adding と同じ式で作られている")
    func expectedMatchesProductionFormula() {
        let ids = ["a", "b", "c"]
        var embeddings: [String: [Float]] = [:]
        for (index, id) in ids.enumerated() { embeddings[id] = vector(index + 1) }
        let qualities: [Float] = [0.42, 0.95, 0.61]
        var sum = [Float](repeating: 0, count: 8)
        var count = 0
        for (index, id) in ids.enumerated() {
            let added = FaceClustering.adding(embeddings[id]!, toSum: sum, count: count,
                                              quality: qualities[index])
            sum = added.sum
            count = added.count
        }
        let state = FaceCentroidAudit.ClusterState(
            clusterID: 1, storedSum: sum, storedCount: count,
            members: ids.enumerated().map { member($0.element, quality: qualities[$0.offset]) })
        let expected = FaceCentroidAudit.expected(for: state, embedding: { embeddings[$0] })
        #expect(expected.count == count)
        #expect(expected.sum == sum)
    }
}
