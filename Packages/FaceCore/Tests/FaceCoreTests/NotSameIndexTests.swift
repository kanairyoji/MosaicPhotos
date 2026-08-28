import Foundation
import Testing
@testable import FaceCore

/// ⚠️ 実機で 27.8 秒のハング（diagnostics-61）。採取したメインスタックが名指しした:
///
///     FaceStore.reviewItems → isMarkedNotSame #1 (Array<Float>, Array<Float>) -> Bool
///
/// クラスタ対の二重ループ（1,020 人＝約 52 万対）の内側で「別人」記録を毎回すべて走査し、
/// 1 記録あたり 512 次元の内積を最大 4 回取っていた。前計算に置き換えたので、
/// **判定結果が元の式と完全に一致すること**を押さえる（ここを外すと別人の統合を提案する）。
@Suite("別人記録の照合（前計算）")
struct NotSameIndexTests {

    /// 元の実装（対ごとに全記録を走査する素朴版）。同値性の基準にする。
    private func naive(_ rows: [([Float], [Float])], _ a: [Float], _ b: [Float]) -> Bool {
        for (ra, rb) in rows {
            if (FaceClustering.dot(a, ra) >= 0.9 && FaceClustering.dot(b, rb) >= 0.9)
                || (FaceClustering.dot(a, rb) >= 0.9 && FaceClustering.dot(b, ra) >= 0.9) {
                return true
            }
        }
        return false
    }

    private func unit(_ v: [Float]) -> [Float] { FaceClustering.normalized(v) }

    @Test("記録した対は別人と判定する")
    func recordedPairIsMarked() {
        let a = unit([1, 0, 0]), b = unit([0, 1, 0])
        let index = NotSameIndex(rows: [(a, b)], centroids: [1: a, 2: b])
        #expect(index.isMarkedNotSame(1, 2))
        #expect(index.isMarkedNotSame(2, 1), "順序を入れ替えても同じ判定でなければならない")
    }

    @Test("無関係な対は別人と判定しない")
    func unrelatedPairIsNotMarked() {
        let a = unit([1, 0, 0]), b = unit([0, 1, 0]), c = unit([0, 0, 1])
        let index = NotSameIndex(rows: [(a, b)], centroids: [1: a, 2: b, 3: c])
        #expect(!index.isMarkedNotSame(1, 3))
        #expect(!index.isMarkedNotSame(2, 3))
    }

    @Test("記録が無ければ何も別人にしない")
    func emptyRows() {
        let index = NotSameIndex(rows: [], centroids: [1: unit([1, 0, 0]), 2: unit([0, 1, 0])])
        #expect(index.isEmpty)
        #expect(!index.isMarkedNotSame(1, 2))
    }

    @Test("しきい値未満の一致は拾わない")
    func belowThreshold() {
        let a = unit([1, 0, 0]), b = unit([0, 1, 0])
        let slightlyOff = unit([0.5, 0.5, 0])          // a とも b とも 0.707＝0.9 未満
        let index = NotSameIndex(rows: [(a, b)], centroids: [1: slightlyOff, 2: b])
        #expect(!index.isMarkedNotSame(1, 2))
    }

    /// 素朴版との**総当たり一致**。前計算で判定が変わっていないことの本体。
    @Test("素朴版と全対で一致する")
    func matchesNaiveForAllPairs() {
        // 適当だが決定的なベクトル群（乱数は使わない）。
        func vector(_ seed: Int) -> [Float] {
            unit([Float(seed % 7) + 0.5, Float((seed * 3) % 5) + 0.25, Float((seed * 5) % 3) + 0.1])
        }
        var centroids: [Int: [Float]] = [:]
        for i in 0..<24 { centroids[i] = vector(i) }
        let rows = (0..<6).map { (vector($0 * 2), vector($0 * 2 + 1)) }

        let index = NotSameIndex(rows: rows, centroids: centroids)
        for a in centroids.keys {
            for b in centroids.keys where a < b {
                #expect(index.isMarkedNotSame(a, b)
                        == naive(rows, centroids[a]!, centroids[b]!),
                        "対 (\(a), \(b)) で素朴版と食い違う＝別人の統合を提案しかねない")
            }
        }
    }

    @Test("同じ側に両方が一致しても別人にはしない")
    func sameSideDoesNotMark() {
        // 「a 側」に 2 つのクラスタが一致しても、反対側との対応が無ければ別人記録ではない。
        let a = unit([1, 0, 0]), b = unit([0, 1, 0])
        let nearA = unit([0.99, 0.01, 0])
        let index = NotSameIndex(rows: [(a, b)], centroids: [1: a, 2: nearA])
        #expect(!index.isMarkedNotSame(1, 2))
    }
}
