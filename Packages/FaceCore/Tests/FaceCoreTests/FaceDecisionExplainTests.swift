import Foundation
import Testing
@testable import FaceCore

/// 「なぜ合流しないか」の説明が、実際の割り当て規則と同じ結論になること（ADR-135）。
///
/// ⚠️ ここがずれると**デバッグ表示が嘘をつく**——チューニングの土台が崩れるので、
/// 説明側（純関数）と実装側（`FaceClustering.assign`）の両方を同じ入力で突き合わせる。
@Suite("判定の内訳（説明）")
struct FaceDecisionExplainTests {

    private let settings = FaceDecisionSettings(
        threshold: 0.50, baseThreshold: 0.50, assignMargin: 0.05,
        sizeAdaptiveMarginMax: 0.10, matureCount: 11,
        negativeSameThreshold: 0.55, mergeBandFloor: 0.40)

    @Test("サイズ適応マージンの式が FaceClustering と一致する")
    func sizeMarginMatchesClustering() {
        var clustering = FaceClustering(threshold: 0.50)
        clustering.sizeAdaptiveMarginMax = 0.10
        clustering.sizeAdaptiveMatureCount = 11
        for count in [1, 2, 5, 10, 11, 40] {
            #expect(abs(settings.sizeMargin(forCount: count)
                        - clustering.sizeMargin(forCount: count)) < 0.0001,
                    "count=\(count) で説明と実装がずれている")
        }
    }

    @Test("小さい相手は上乗せで届かない（素のしきい値は超えている）")
    func blockedBySizeMargin() {
        // count=1 → 上乗せ 0.10 → 実効 0.60。0.55 は素の 0.50 を超えるが届かない。
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.55, targetCount: 1), settings: settings)
        #expect(v == .blockedBySizeMargin(required: 0.60))
    }

    @Test("成熟した相手には上乗せ無しで入る")
    func joinsMatureCluster() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.55, targetCount: 40), settings: settings)
        #expect(v == .joins)
    }

    @Test("1 位と 2 位が紛らわしいとマージンゲートで止まる")
    func blockedByMargin() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.62, targetCount: 40, runnerUpSimilarity: 0.60),
            settings: settings)
        #expect(v == .blockedByMargin(gap: 0.62 - 0.60))
    }

    @Test("負例・同一写真・別名は理由が分かれて出る")
    func explicitBlockers() {
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, negativeRejected: true),
            settings: settings) == .blockedByNegative)
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, sharesPhoto: true),
            settings: settings) == .samePhoto)
        #expect(FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.7, targetCount: 40, nameConflict: true),
            settings: settings) == .differentNames)
    }

    @Test("しきい値未満は「届かない」")
    func belowThreshold() {
        let v = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: 0.30, targetCount: 40), settings: settings)
        #expect(v == .belowThreshold(required: 0.50))
    }

    /// 説明と実装の突き合わせ: 同じ 2 クラスタ構成で `assign` の結果と結論が一致する。
    @Test("説明の結論が assign の実際の挙動と一致する")
    func matchesActualAssign() {
        // 成熟クラスタ（12 顔）と小クラスタ（1 顔）を作り、両方に 0.55 で似た顔を入れる。
        var clustering = FaceClustering(threshold: 0.50)
        clustering.sizeAdaptiveMarginMax = 0.10
        clustering.sizeAdaptiveMatureCount = 11
        for i in 0..<12 { _ = clustering.assign(faceID: "m\(i)", embedding: [1, 0, 0]) }
        _ = clustering.assign(faceID: "s0", embedding: [0, 1, 0])
        // fixture の前提: 成熟クラスタ 12 顔・小クラスタ 1 顔。
        #expect(clustering.clusters.count == 2)
        #expect(clustering.clusters[0].count == 12)
        #expect(clustering.clusters[1].count == 1)

        // 小クラスタにだけ cos 0.55 で似ている顔（成熟側とは 0.2）。
        let probe: [Float] = FaceClustering.normalized([0.2, 0.55, 0.81])
        let simSmall = FaceClustering.dot(probe, clustering.clusters[1].centroid)
        let verdict = FaceDecisionExplain.verdict(
            FaceDecisionInputs(similarity: simSmall, targetCount: 1), settings: settings)
        let assigned = clustering.assign(faceID: "probe", embedding: probe)
        // 説明が「上乗せで入らない」と言うなら、実際にも小クラスタへは入らない。
        if case .blockedBySizeMargin = verdict {
            #expect(assigned != clustering.clusters[1].id)
        } else {
            Issue.record("fixture: 上乗せで弾かれる位置になっていない（sim=\(simSmall)）")
        }
    }
}
