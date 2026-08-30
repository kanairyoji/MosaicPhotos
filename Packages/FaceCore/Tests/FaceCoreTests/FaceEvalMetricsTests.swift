import Foundation
import Testing
@testable import FaceCore

/// 精度指標（B-Cubed / ペア一致 / TAR@FAR）の純ロジック検証。
@Suite("FaceEvalMetrics")
struct FaceEvalMetricsTests {

    @Test("完全一致のクラスタリングは全指標 1.0")
    func perfectClustering() {
        let assignments = ["a1": 1, "a2": 1, "b1": 2, "b2": 2]
        let truth = ["a1": "A", "a2": "A", "b1": "B", "b2": "B"]
        let s = FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth)
        #expect(s != nil)
        #expect(abs(s!.bcubedF1 - 1.0) < 1e-9)
        #expect(abs(s!.pairF1 - 1.0) < 1e-9)
    }

    @Test("全部 1 クラスタは recall=1・precision が下がる（混入の検出）")
    func overMerged() {
        let assignments = ["a1": 1, "a2": 1, "b1": 1, "b2": 1]
        let truth = ["a1": "A", "a2": "A", "b1": "B", "b2": "B"]
        let s = FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth)!
        #expect(abs(s.bcubedRecall - 1.0) < 1e-9)
        #expect(abs(s.bcubedPrecision - 0.5) < 1e-9)
        // ペア: TP=2, FP=4 → P=1/3, R=1
        #expect(abs(s.pairPrecision - 1.0 / 3) < 1e-9)
        #expect(abs(s.pairRecall - 1.0) < 1e-9)
    }

    @Test("全部バラバラは precision=1・recall が下がる（分裂の検出）")
    func overSplit() {
        let assignments = ["a1": 1, "a2": 2, "b1": 3, "b2": 4]
        let truth = ["a1": "A", "a2": "A", "b1": "B", "b2": "B"]
        let s = FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth)!
        #expect(abs(s.bcubedPrecision - 1.0) < 1e-9)
        #expect(abs(s.bcubedRecall - 0.5) < 1e-9)
        #expect(abs(s.pairRecall - 0.0) < 1e-9)
    }

    @Test("検証スコア: 分離が完全なら TAR=100%・最良しきい値が間に入る")
    func verificationSeparated() {
        let same: [Float] = [0.7, 0.72, 0.75, 0.8, 0.68]
        let different: [Float] = Array(repeating: 0.30, count: 500) + [0.35, 0.38, 0.40]
        let v = FaceEvalMetrics.verificationScore(sameSims: same, differentSims: different)!
        #expect(v.tarAtFar01 == 1.0)
        #expect(v.bestF1Threshold > 0.40 && v.bestF1Threshold <= 0.68)
        #expect(abs(v.bestF1 - 1.0) < 1e-9)
    }

    @Test("空入力は nil")
    func emptyInputs() {
        #expect(FaceEvalMetrics.verificationScore(sameSims: [], differentSims: [0.1]) == nil)
        #expect(FaceEvalMetrics.clusteringScore(assignments: [:], truth: [:]) == nil)
    }

    /// ⚠️ **平均は小さいアルバムの被害を隠す**（ADR-126 の撤回で学んだ）。
    /// 1 人だけ崩れている構成で、平均は高いまま・最悪値と下位 25% が落ちることを確かめる。
    @Test("平均が高くても、崩れた 1 人は最悪値に出る")
    func perIdentityDistributionExposesOneBadPerson() {
        // A・B・C は綺麗に分かれ、D だけ 2 人分が 1 クラスタに混ざっている。
        var assignments: [String: Int] = [:]
        var truth: [String: String] = [:]
        for (index, person) in ["A", "B", "C"].enumerated() {
            for i in 0..<10 {
                assignments["\(person)\(i)"] = index
                truth["\(person)\(i)"] = person
            }
        }
        // D（5 枚）と E（5 枚）が同じクラスタ 3 に入っている。
        for i in 0..<5 {
            assignments["D\(i)"] = 3; truth["D\(i)"] = "D"
            assignments["E\(i)"] = 3; truth["E\(i)"] = "E"
        }
        guard let score = FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth) else {
            Issue.record("スコアが出ていない"); return
        }
        // 平均（B-Cubed 純度）は高いまま——ここだけ見ていると気づけない。
        #expect(score.bcubedPrecision > 0.8)
        // 崩れた人物は最悪値・下位 25%・「純度 0.8 未満の人数」に出る。
        #expect(score.worstIdentityPrecision == 0.5)
        #expect(score.p25IdentityPrecision <= 0.5)
        #expect(score.identitiesBelow80Precision == 2, "混ざった 2 人が数えられていない")
        // 分裂は起きていないので再現率は落ちない。
        #expect(score.worstIdentityRecall == 1.0)
    }

    @Test("分裂した人物は再現率の最悪値に出る")
    func splitIdentityShowsInRecall() {
        var assignments: [String: Int] = [:]
        var truth: [String: String] = [:]
        for i in 0..<10 { assignments["A\(i)"] = 0; truth["A\(i)"] = "A" }
        // B は 2 つに割れている（5 枚ずつ）。
        for i in 0..<5 { assignments["B\(i)"] = 1; truth["B\(i)"] = "B" }
        for i in 5..<10 { assignments["B\(i)"] = 2; truth["B\(i)"] = "B" }
        guard let score = FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth) else {
            Issue.record("スコアが出ていない"); return
        }
        #expect(score.worstIdentityPrecision == 1.0, "混入は無いので純度は落ちない")
        #expect(score.worstIdentityRecall == 0.5, "分裂が再現率に出ていない")
        #expect(score.maxClustersForOneIdentity == 2)
    }

    /// 「尋ねる下限」を決める曲線（ADR-150）。当たり率と、取りこぼす分の裏返しを同時に見る。
    @Test("候補帯: 下限を上げると当たり率は上がり、拾える分裂は減る")
    func candidateBandCurveTradesPrecisionForCoverage() {
        // 同一人物 A が 2 つに割れている（cos 0.95）。B は別人（A とは cos 0.30）。
        let clusters: [(centroid: [Float], identity: String)] = [
            (FaceClustering.normalized([1, 0, 0]), "A"),
            (FaceClustering.normalized([0.95, 0.312, 0]), "A"),
            (FaceClustering.normalized([0.30, 0.954, 0]), "B"),
        ]
        let curve = FaceEvalMetrics.candidateBandCurve(clusters: clusters, bars: [0.2, 0.5, 0.9])
        #expect(curve.count == 3)
        // 下限 0.2: 3 対すべてを尋ねる → 当たりは 1 対だけ。
        #expect(curve[0].pairs == 3)
        #expect(curve[0].samePerson == 1)
        #expect(abs(curve[0].precision - 1.0 / 3.0) < 0.001)
        #expect(curve[0].splitCoverage == 1.0)
        // 下限 0.9: A の 2 つだけが残る＝当たり率 100%・分裂も拾えている。
        #expect(curve[2].pairs == 1)
        #expect(curve[2].precision == 1.0)
        #expect(curve[2].splitCoverage == 1.0)
    }

    @Test("候補帯: 下限が高すぎると分裂を拾えなくなる")
    func candidateBandCurveLosesSplits() {
        // 同一人物 A が cos 0.6 で割れている（成長・角度差）。
        let clusters: [(centroid: [Float], identity: String)] = [
            (FaceClustering.normalized([1, 0, 0]), "A"),
            (FaceClustering.normalized([0.6, 0.8, 0]), "A"),
        ]
        let curve = FaceEvalMetrics.candidateBandCurve(clusters: clusters, bars: [0.5, 0.8])
        #expect(curve[0].splitCoverage == 1.0, "0.5 なら拾える")
        #expect(curve[1].pairs == 0)
        #expect(curve[1].splitCoverage == 0.0, "0.8 では取りこぼす")
    }
}
