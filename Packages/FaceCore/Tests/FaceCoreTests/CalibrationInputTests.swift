import PerceptionCore
import Foundation
import Testing
@testable import FaceCore

/// 校正の入力（ADR-149）。実機 9,973 件の実測から見つかった 2 つの欠陥を止める。
///
/// 1. **尺度の混在**: 校正しているのは「顔が人物に入る」しきい値（顔×重心）なのに、
///    人物ペア（重心×重心）の回答まで混ぜていた。
/// 2. **分離しないデータでの最適化**: 顔レベルの正例と負例は AUC 0.472＝コイン投げ以下で、
///    そこから「最もよく分ける境界」を探すと、件数の多い側を全部落とす端が答えになり、
///    可動域の上限に張り付く（＝直すほど厳しくなる）。
@Suite("校正の入力", .serialized)
struct CalibrationInputTests {

    @Test("人物ペアの回答（重心×重心）は顔のしきい値を動かさない")
    func personPairAnswersDoNotMoveFaceThreshold() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let base = await store.calibratedThreshold()

        // 人物ペアの回答だけを大量に入れる（尺度が違うので効いてはいけない）。
        for i in 0..<40 {
            await store.recordCorrectionForTesting(kind: "merge", similarity: 0.80 + Float(i) * 0.001)
            await store.recordCorrectionForTesting(kind: "notSame", similarity: 0.30 + Float(i) * 0.001)
        }
        #expect(await store.calibratedThreshold() == base, "人物ペアの回答でしきい値が動いた")
    }

    @Test("顔の回答が分離していなければ校正しない（既定値のまま）")
    func overlappingFaceAnswersDoNotCalibrate() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let base = await store.calibratedThreshold()
        // 実機と同じ形: confirm と reassign が同じ範囲に重なっている。
        for i in 0..<40 {
            await store.recordCorrectionForTesting(kind: "confirm", similarity: 0.50 + Float(i % 20) * 0.01)
            await store.recordCorrectionForTesting(kind: "reassign", similarity: 0.50 + Float(i % 20) * 0.01)
        }
        #expect(await store.calibratedThreshold() == base, "分離していないのに校正された")
    }

    @Test("顔の回答が分離していれば校正する")
    func separableFaceAnswersCalibrate() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let base = await store.calibratedThreshold()
        for i in 0..<20 {
            await store.recordCorrectionForTesting(kind: "confirm", similarity: 0.70 + Float(i) * 0.002)
            await store.recordCorrectionForTesting(kind: "reassign", similarity: 0.30 + Float(i) * 0.002)
        }
        let calibrated = await store.calibratedThreshold()
        #expect(calibrated != base, "分離しているのに校正されていない")
    }

    /// 実測（AUC 0.472）と同じ形を数値で確かめる。
    @Test("分離度は順位で測る（尺度に依らない）")
    func separabilityIsRankBased() {
        #expect(FaceCalibration.separability(positive: [0.9, 0.8, 0.7],
                                             negative: [0.3, 0.2, 0.1]) == 1.0)
        #expect(FaceCalibration.separability(positive: [0.3, 0.2, 0.1],
                                             negative: [0.9, 0.8, 0.7]) == 0.0)
        // 完全に重なっていれば 0.5（無関係）。
        #expect(FaceCalibration.separability(positive: [0.5, 0.6], negative: [0.5, 0.6]) == 0.5)
    }
}
