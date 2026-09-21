import Foundation
import Testing
@testable import FaceCore

/// 連写の連結（ADR-211）。**足すだけ・矛盾したら何もしない**という安全側の性質を固定する。
@Suite("連写の連結（ADR-211）")
struct TemporalLinkingTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func box(_ x: Double, _ y: Double, _ size: Double = 0.2) -> TemporalLinking.Box {
        .init(x: x, y: y, width: size, height: size)
    }

    private func face(_ id: String, photo: String, at offset: TimeInterval,
                      box: TemporalLinking.Box, cluster: Int = FaceClustering.unassigned,
                      contributes: Bool = false) -> TemporalLinking.Face {
        .init(faceID: id, refKey: photo, captureDate: base.addingTimeInterval(offset),
              box: box, clusterID: cluster, contributes: contributes)
    }

    // MARK: - 重なりの計算

    @Test("IoU は同じ矩形で 1・離れていれば 0")
    func iouBasics() {
        #expect(abs(box(0.1, 0.1).iou(box(0.1, 0.1)) - 1) < 1e-9)
        #expect(box(0.1, 0.1).iou(box(0.8, 0.8)) == 0)
        #expect(box(0.1, 0.1, 0).iou(box(0.1, 0.1)) == 0)   // 退化した矩形
    }

    // MARK: - 繋ぐ

    /// 連写でぶれた 1 枚（未割当）を、同じ位置の確立した顔へ繋ぐ。
    @Test("連写の同じ位置にある未割当の顔を、人物へ繋ぐ")
    func linksBlurredFaceInBurst() {
        let plan = TemporalLinking.plan(faces: [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("a1", photo: "p1", at: 0.3, box: box(0.11, 0.1)),
            face("a2", photo: "p2", at: 0.6, box: box(0.12, 0.1), cluster: 7, contributes: true),
        ])
        #expect(plan.links == [.init(faceID: "a1", clusterID: 7)])
        #expect(plan.conflicts == 0)
    }

    /// ⚠️ **足すだけ**。既に人物が決まっている顔は動かさない。
    @Test("既に割り当て済みの顔は動かさない")
    func neverMovesAnExistingAssignment() {
        let plan = TemporalLinking.plan(faces: [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("a1", photo: "p1", at: 0.3, box: box(0.1, 0.1), cluster: 9, contributes: true),
        ])
        #expect(plan.links.isEmpty)
        // 1 本のトラックで証拠が割れている＝繋がない。
        #expect(plan.conflicts == 1)
    }

    /// membership だけで入った顔（第2パス・前回の連結）は証拠にしない——
    /// 推測が推測を裏づける循環を断つ。
    @Test("重心を作っていない顔は人物の証拠にならない")
    func membershipOnlyIsNotEvidence() {
        let plan = TemporalLinking.plan(faces: [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: false),
            face("a1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
        ])
        #expect(plan.links.isEmpty)
    }

    // MARK: - 繋がない

    @Test("間隔が開いていれば別の場面（同じ位置でも繋がない）")
    func gapBreaksTheBurst() {
        let plan = TemporalLinking.plan(faces: [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("a1", photo: "p1", at: 30, box: box(0.1, 0.1)),
        ])
        #expect(plan.links.isEmpty)
    }

    @Test("位置が離れていれば繋がない（隣に立つ人を巻き込まない）")
    func distantBoxIsNotLinked() {
        let plan = TemporalLinking.plan(faces: [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("b1", photo: "p1", at: 0.3, box: box(0.7, 0.1)),
        ])
        #expect(plan.links.isEmpty)
    }

    @Test("撮影日が無い顔は連写の判断に参加しない")
    func undatedFacesAreIgnored() {
        let plan = TemporalLinking.plan(faces: [
            .init(faceID: "a0", refKey: "p0", captureDate: nil, box: box(0.1, 0.1),
                  clusterID: 7, contributes: true),
            .init(faceID: "a1", refKey: "p1", captureDate: nil, box: box(0.1, 0.1),
                  clusterID: FaceClustering.unassigned, contributes: false),
        ])
        #expect(plan.links.isEmpty)
    }

    @Test("負例（この人ではない）で止められた連結は行わない")
    func negativeBlocksTheLink() {
        let faces = [
            face("a0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("a1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
        ]
        let plan = TemporalLinking.plan(faces: faces) { faceID, cluster in
            faceID == "a1" && cluster == 7
        }
        #expect(plan.links.isEmpty)
    }

    // MARK: - 同一写真 cannot-link の連鎖（ADR-211 の肝）

    /// 1 枚でも居合わせた 2 本のトラックは、その連写のあいだずっと別人。
    /// どちらかが必ず間違っているので、**両方の証拠を捨てる**。
    @Test("居合わせた 2 本が同じ人物を指したら、どちらも繋がない")
    func coOccurringTracksClaimingTheSamePersonAreDropped() {
        let plan = TemporalLinking.plan(faces: [
            face("L0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("R0", photo: "p0", at: 0, box: box(0.7, 0.1), cluster: 7, contributes: true),
            face("L1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
            face("R1", photo: "p1", at: 0.3, box: box(0.7, 0.1)),
        ])
        #expect(plan.links.isEmpty)
        #expect(plan.conflicts >= 1)
    }

    /// 別々の人物を指す 2 本なら、両方とも繋がる（普通の 2 人の連写）。
    @Test("居合わせた 2 本が別の人物なら、それぞれ繋がる")
    func twoPeopleInABurstBothGetLinked() {
        let plan = TemporalLinking.plan(faces: [
            face("L0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("R0", photo: "p0", at: 0, box: box(0.7, 0.1), cluster: 9, contributes: true),
            face("L1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
            face("R1", photo: "p1", at: 0.3, box: box(0.7, 0.1)),
        ])
        #expect(plan.links == [.init(faceID: "L1", clusterID: 7),
                               .init(faceID: "R1", clusterID: 9)])
    }

    /// ⚠️ **1 枚の写真に同じ人が 2 回**という状態を、こちらが作ってはいけない。
    /// 隣のトラックが membership だけでその人物に入っている場合も含めて見る。
    @Test("その写真に既にその人物が居るなら繋がない")
    func doesNotPutTheSamePersonTwiceInOnePhoto() {
        let plan = TemporalLinking.plan(faces: [
            face("L0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("L1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
            // 同じ写真 p1 の別の顔が、既にクラスタ 7 に membership で入っている。
            face("X1", photo: "p1", at: 0.3, box: box(0.7, 0.5), cluster: 7, contributes: false),
        ])
        #expect(plan.links.isEmpty)
    }

    // MARK: - 決定的であること

    /// 同じ台帳から毎晩違うトラックができると、再現できない不具合になる（ADR-139 と同じ罠）。
    @Test("入力の並びが変わっても結果は同じ")
    func resultIsIndependentOfInputOrder() {
        let faces = [
            face("L0", photo: "p0", at: 0, box: box(0.1, 0.1), cluster: 7, contributes: true),
            face("R0", photo: "p0", at: 0, box: box(0.7, 0.1), cluster: 9, contributes: true),
            face("L1", photo: "p1", at: 0.3, box: box(0.1, 0.1)),
            face("R1", photo: "p1", at: 0.3, box: box(0.72, 0.1)),
            face("L2", photo: "p2", at: 0.6, box: box(0.1, 0.1)),
        ]
        let forward = TemporalLinking.plan(faces: faces)
        let reversed = TemporalLinking.plan(faces: faces.reversed())
        #expect(forward.links == reversed.links)
        #expect(!forward.links.isEmpty)
    }
}
