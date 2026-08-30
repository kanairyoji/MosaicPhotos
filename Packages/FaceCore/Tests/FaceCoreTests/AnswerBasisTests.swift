import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 「あなたの回答から見た基準」（ADR-148 Step 1）。
///
/// ⚠️ しきい値を感覚で動かすと、直すほど別の壊れ方をする（ADR-140/141 で経験した）。
/// ユーザーが実際に「同じ人」「別人」と答えたペアの類似度分布を出し、
/// **自分のデータで境界を読む**ための材料が正しく作れることを押さえる。
@Suite("あなたの回答から見た基準", .serialized)
struct AnswerBasisTests {

    @Test("分布の要約（中央値・分位・ヒストグラム）")
    func summarizeDistribution() {
        let side = FaceStore.summarize([0.10, 0.25, 0.25, 0.40, 0.95])
        #expect(side.count == 5)
        #expect(side.median == 0.25)
        #expect(side.p10 == 0.10)
        #expect(side.p90 == 0.95)
        #expect(side.histogram[1] == 1, "0.10 は 10–20% のバケット")
        #expect(side.histogram[2] == 2, "0.25 が 2 件")
        #expect(side.histogram[9] == 1, "0.95 は 90–100%")
        #expect(side.histogram.reduce(0, +) == 5)
    }

    @Test("空でも壊れない")
    func summarizeEmpty() {
        let side = FaceStore.summarize([])
        #expect(side.count == 0)
        #expect(side.histogram.count == 10)
        #expect(side.histogram.allSatisfy { $0 == 0 })
    }

    /// 回答の種類ごとに**尺度が違う**ので混ぜない（人物どうし＝重心×重心、顔と人物＝顔×重心）。
    @Test("種類ごとに分けて集計し、少数の回答では境界を出さない")
    func profileSeparatesKinds() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 「同じ人」と答えた人物ペアを 10 件（高い類似度）、「別人」を 10 件（低い）。
        for i in 0..<10 {
            await store.recordCorrectionForTesting(kind: "merge", similarity: 0.70 + Float(i) * 0.01)
            await store.recordCorrectionForTesting(kind: "notSame", similarity: 0.30 + Float(i) * 0.01)
        }
        // 顔と人物の回答も混ぜる（こちらは別の尺度）。
        for i in 0..<5 {
            await store.recordCorrectionForTesting(kind: "confirm", similarity: 0.50 + Float(i) * 0.01)
            await store.recordCorrectionForTesting(kind: "reassign", similarity: 0.20 + Float(i) * 0.01)
        }

        let pair = await store.answerSimilarityProfile(kind: .personPair)
        #expect(pair.same.count == 10)
        #expect(pair.different.count == 10)
        #expect(pair.separation > 0.3, "同じ人と別人が分かれていない")
        guard let bar = pair.bestBar else {
            Issue.record("十分な回答があるのに境界が出ていない"); return
        }
        #expect(bar > 0.39 && bar <= 0.71, "境界が 2 つの分布の間に無い: \(bar)")
        #expect(pair.sameBelowBar == 0)
        #expect(pair.differentAboveBar == 0)

        // 顔と人物は回答が 5 件ずつ＝下限未満なので境界は出さない（少数で基準を動かさない）。
        let face = await store.answerSimilarityProfile(kind: .faceToPerson)
        #expect(face.same.count == 5)
        #expect(face.different.count == 5)
        #expect(face.bestBar == nil)
    }
}
