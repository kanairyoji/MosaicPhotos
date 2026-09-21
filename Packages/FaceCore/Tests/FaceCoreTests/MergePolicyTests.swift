import Foundation
import Testing
@testable import FaceCore

/// 「どこまで機械がやってよいか」の表（ADR-213）。
///
/// ⚠️ 値は `face-accuracy.md` の実測で決まっている（ADR-153/154/155）。ここは
/// **集めて意味を与えただけ**で 1 つも動かしていない——それを固定する。
@Suite("統合の帯（ADR-213）")
struct MergePolicyTests {

    private let bars = MergePolicy.bars(tuning: .arcFace, threshold: 0.35)

    @Test("帯は 無視 → 尋ねる → 事前選択 → 自動吸収 の順に上がる")
    func bandsAreOrdered() {
        #expect(bars.askFloor == 0.40)      // arcface の mergeCandidateFloor
        #expect(bars.absorb == 0.75)
        #expect(bars.preselect == 0.85)
        #expect(bars.askFloor < bars.absorb && bars.absorb < bars.preselect)
    }

    @Test("下限に届かない対は何もしない（尋ねても当たらない帯）")
    func belowFloorIsIgnored() {
        #expect(MergePolicy.action(similarity: 0.39, isFragmentToPerson: true, bars: bars)
                    == .ignore)
        #expect(MergePolicy.action(similarity: 0.39, isFragmentToPerson: false, bars: bars)
                    == .ignore)
    }

    /// ⚠️⚠️ **人物どうしは、どれだけ似ていても自動で結合しない**（ADR-153）。
    /// ユーザー自身が 0.885 / 0.920 の対を「別人」と答えている。
    @Test("人物どうしは自動で結合しない（どれだけ似ていても）")
    func peopleAreNeverMergedAutomatically() {
        for similarity in [Float(0.75), 0.85, 0.95, 1.0] {
            #expect(MergePolicy.action(similarity: similarity, isFragmentToPerson: false,
                                       bars: bars) != .absorb)
        }
    }

    @Test("断片 → 確立した人物だけが自動で寄る")
    func onlyFragmentsAreAbsorbed() {
        #expect(MergePolicy.action(similarity: 0.76, isFragmentToPerson: true, bars: bars)
                    == .absorb)
        #expect(MergePolicy.action(similarity: 0.76, isFragmentToPerson: false, bars: bars)
                    == .ask)
    }

    @Test("高い帯は『チェックを付けて見せる』（黙って結合はしない）")
    func highBandIsPreselectedNotMerged() {
        #expect(MergePolicy.action(similarity: 0.86, isFragmentToPerson: false, bars: bars)
                    == .preselect)
        #expect(MergePolicy.action(similarity: 0.84, isFragmentToPerson: false, bars: bars)
                    == .ask)
    }

    /// 尋ねる下限は**しきい値より下へ降りない**（ADR-150: 下げると 96% が当たらない対になる）。
    @Test("尋ねる下限は校正で上がったしきい値に追随する")
    func askFloorFollowsCalibration() {
        let raised = MergePolicy.bars(tuning: .arcFace, threshold: 0.50)
        #expect(raised.askFloor == 0.50)
    }

    /// ⚠️ 値の正本がここに移ったことを固定する（呼び出し側の別名とずれたら意味がない）。
    @Test("形の定数は FaceStore の別名と同じ値を指す")
    func structuralConstantsAreShared() {
        #expect(FaceStore.absorbMaxPhotos == MergePolicy.absorbMaxPhotos)
        #expect(FaceStore.absorbTargetMinPhotos == MergePolicy.absorbTargetMinPhotos)
        #expect(FaceStore.absorbMargin == MergePolicy.absorbMargin)
        #expect(FaceStore.absorbLimitPerRun == MergePolicy.absorbLimitPerRun)
        #expect(FaceStore.coOccurrenceNotSame == MergePolicy.coOccurrenceNotSame)
        // ADR-155: 上限は 2 のまま（データセットが「上げると誤る」としか言っていない）。
        #expect(MergePolicy.absorbMaxPhotos == 2)
    }
}
