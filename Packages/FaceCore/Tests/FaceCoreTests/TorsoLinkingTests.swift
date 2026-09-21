import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 服装（胴体）の連結（ADR-212）。**使ってよい範囲**（同じ場面・両方が胴体を持つ・
/// 胴体だけで人物を作らない・紛らわしければ繋がない）が守られていることを固定する。
@Suite("服装の連結（ADR-212）")
struct TorsoLinkingTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let floor: Float = 0.30   // arcface の torsoFaceFloor

    /// 3 次元の単位ベクトル（角度で似方を作る）。
    private func unit(_ degrees: Float) -> [Float] {
        let r = degrees * .pi / 180
        return [cos(r), sin(r), 0]
    }

    private func face(_ id: String, photo: String, at offset: TimeInterval,
                      cluster: Int = FaceClustering.unassigned, contributes: Bool = false,
                      faceAngle: Float, torsoAngle: Float?) -> TorsoLinking.Face {
        .init(faceID: id, refKey: photo, captureDate: base.addingTimeInterval(offset),
              clusterID: cluster, contributes: contributes,
              embedding: unit(faceAngle), torso: torsoAngle.map { unit($0) })
    }

    private func plan(_ faces: [TorsoLinking.Face],
                      isBlocked: @escaping (String, Int) -> Bool = { _, _ in false })
        -> TorsoLinking.Plan {
        TorsoLinking.plan(faces: faces, faceFloor: floor, isBlocked: isBlocked)
    }

    // MARK: - 場面の切れ目

    @Test("場面は間隔で切れる（切れ目の区間を返す）")
    func sessionsSplitOnGap() {
        let dates = [0.0, 10, 20, 7200, 7210].map { base.addingTimeInterval($0) }
        #expect(TorsoLinking.sessionBoundaries(dates: dates) == [0..<3, 3..<5])
        #expect(TorsoLinking.sessionBoundaries(dates: []).isEmpty)
    }

    // MARK: - 繋ぐ

    /// 顔だけでは届かない（第2パスの線 0.40 未満）が、服が実質同じ写り＝繋ぐ。
    @Test("同じ場面で服が一致すれば、顔が弱くても繋がる")
    func linksWhenClothingMatches() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("rival", photo: "p0", at: 0, cluster: 9, contributes: true,
                 faceAngle: 80, torsoAngle: 70),
            face("blurry", photo: "p1", at: 5, faceAngle: 40, torsoAngle: 2),
        ])
        #expect(result.links.map(\.faceID) == ["blurry"])
        #expect(result.links.first?.clusterID == 7)
    }

    // MARK: - 繋がない（安全弁）

    /// ⚠️ **胴体だけで人物を作らない**。繋ぎ先はその場面で**顔が**確立している人物に限る。
    @Test("その場面に顔で確立した人物が居なければ何もしない")
    func neverCreatesAPersonFromClothingAlone() {
        let result = plan([
            face("x", photo: "p0", at: 0, faceAngle: 0, torsoAngle: 0),
            face("y", photo: "p1", at: 5, faceAngle: 1, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
    }

    /// membership だけで入った顔は「確立している」とは言わない。
    @Test("重心を作っていない顔は繋ぎ先の根拠にならない")
    func membershipOnlyAnchorIsIgnored() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: false,
                 faceAngle: 0, torsoAngle: 0),
            face("blurry", photo: "p1", at: 5, faceAngle: 1, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
    }

    @Test("場面が違えば服が同じでも繋がない（服はその日のもの）")
    func differentSessionIsNeverLinked() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("blurry", photo: "p1", at: 7200, faceAngle: 1, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
    }

    /// ⚠️ 片方でも胴体が欠けたら、**無音で**顔だけの判断に戻る。
    @Test("胴体を持たない顔は判断に参加しない")
    func missingTorsoFallsBackSilently() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: nil),
            face("blurry", photo: "p1", at: 5, faceAngle: 1, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
        #expect(result.skipped == 0)   // そもそも候補にならない（見送りとしても数えない）
    }

    /// 顔が積極的に「別人だ」と言っているなら、服が一致しても繋がない。
    @Test("顔の最低線を割っていれば繋がない")
    func faceFloorIsRespected() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("stranger", photo: "p1", at: 5, faceAngle: 89, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
        #expect(result.skipped == 1)
    }

    /// お揃いの服・制服。**1 位と 2 位が紛らわしければ繋がない**（ADR-57 と同じ考え方）。
    @Test("2 人の服が似ていて差が付かなければ繋がない")
    func ambiguousClothingIsNotLinked() {
        let result = plan([
            face("a", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 40, torsoAngle: 0),
            face("b", photo: "p0", at: 0, cluster: 9, contributes: true,
                 faceAngle: 40, torsoAngle: 0.2),
            face("blurry", photo: "p1", at: 5, faceAngle: 40, torsoAngle: 0.1),
        ])
        #expect(result.links.isEmpty)
        #expect(result.skipped == 1)
    }

    @Test("その写真に既にその人物が居るなら繋がない（同一写真 cannot-link）")
    func doesNotPutThePersonTwiceInOnePhoto() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("blurry", photo: "p0", at: 0, faceAngle: 1, torsoAngle: 0),
        ])
        #expect(result.links.isEmpty)
    }

    @Test("負例で止められた連結は行わない")
    func negativeBlocksTheLink() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("blurry", photo: "p1", at: 5, faceAngle: 1, torsoAngle: 0),
        ], isBlocked: { faceID, cluster in faceID == "blurry" && cluster == 7 })
        #expect(result.links.isEmpty)
    }

    // MARK: - バーを決めるための材料

    /// ⚠️ 顔のデータセットには服装が無い。バーを動かす判断は**実機のこの分布**でしかできない
    /// （ADR-162 と同じ手順）。分布は「バー以外の条件を全部通った」候補だけを数える。
    @Test("バー別に繋がる数を数える（バーを動かす判断の材料）")
    func probeCountsQualifiedCandidatesPerBar() {
        let result = plan([
            face("anchor", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            // 胴体の類似 ≈ cos(25°) ≈ 0.906 → 0.80/0.85/0.90 は通り 0.95 は通らない。
            face("mid", photo: "p1", at: 5, faceAngle: 1, torsoAngle: 25),
        ])
        #expect(result.probe[0.80] == 1)
        #expect(result.probe[0.85] == 1)
        #expect(result.probe[0.90] == 1)
        #expect(result.probe[0.95] == 0)
        #expect(result.links.map(\.faceID) == ["mid"])   // 既定バー 0.90 は超えている
    }

    // MARK: - 尺度の混ぜ方

    /// 順位づけは重み付き和（顔 7 : 胴体 3）。可否は相対差で決めるので尺度に依らない。
    @Test("スコアは顔 7 : 胴体 3")
    func scoreWeightsFaceSeventy() {
        #expect(abs(TorsoLinking.score(face: 1, torso: 0) - 0.7) < 1e-6)
        #expect(abs(TorsoLinking.score(face: 0, torso: 1) - 0.3) < 1e-6)
    }

    @Test("入力の並びが変わっても結果は同じ")
    func resultIsIndependentOfInputOrder() {
        let faces = [
            face("a", photo: "p0", at: 0, cluster: 7, contributes: true,
                 faceAngle: 0, torsoAngle: 0),
            face("b", photo: "p0", at: 0, cluster: 9, contributes: true,
                 faceAngle: 85, torsoAngle: 80),
            face("blurry", photo: "p1", at: 5, faceAngle: 40, torsoAngle: 2),
        ]
        #expect(plan(faces).links == plan(faces.reversed()).links)
        #expect(!plan(faces).links.isEmpty)
    }
}

/// 胴体の領域（ADR-212）。**はみ出したら諦める**のが要点。
@Suite("胴体の領域（ADR-212）")
struct TorsoRegionTests {

    @Test("顔の真下に、幅 2 倍・高さ 2.5 倍で取る")
    func boxIsBelowTheFace() {
        let face = CGRect(x: 0.4, y: 0.5, width: 0.1, height: 0.1)
        let torso = TorsoRegion.normalizedBox(forFace: face)
        #expect(torso != nil)
        // 顔の中心（0.45）に合わせて幅 0.2 → x は 0.35。
        #expect(abs(torso!.minX - 0.35) < 1e-6)
        #expect(abs(torso!.width - 0.2) < 1e-6)
        // 顔の下端（0.5）から下へ 0.25。
        #expect(abs(torso!.maxY - 0.5) < 1e-6)
        #expect(abs(torso!.height - 0.25) < 1e-6)
    }

    /// 引きの写真で人物が画面の下端に写っていると胴体はほとんど入らない。
    /// 切れた胴体を「服」として比べると、床や机を比べることになる。
    @Test("画面からはみ出しすぎたら諦める")
    func givesUpWhenMostlyOutOfFrame() {
        let low = CGRect(x: 0.4, y: 0.02, width: 0.1, height: 0.1)
        #expect(TorsoRegion.normalizedBox(forFace: low) == nil)
    }

    @Test("退化した顔矩形は領域を作らない")
    func degenerateFaceHasNoTorso() {
        #expect(TorsoRegion.normalizedBox(forFace: CGRect(x: 0.4, y: 0.5, width: 0, height: 0.1))
                    == nil)
    }
}
