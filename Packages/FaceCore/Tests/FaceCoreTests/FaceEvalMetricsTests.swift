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
}
