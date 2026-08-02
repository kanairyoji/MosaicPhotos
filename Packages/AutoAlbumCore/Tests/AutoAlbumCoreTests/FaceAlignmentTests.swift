import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// 顔アライメント計画（ADR-51）と版上げ時の名前持ち越し。
@Suite("FaceAlignment + name carryover", .serialized)
struct FaceAlignmentTests {

    private let box = CGRect(x: 100, y: 100, width: 200, height: 220)

    @Test("水平な目は回転 0・辺は bbox 長辺×1.6・目標は上から 35%")
    func horizontalEyes() {
        let plan = FaceAlignment.plan(leftEye: CGPoint(x: 150, y: 220),
                                      rightEye: CGPoint(x: 250, y: 220),
                                      pixelBox: box)
        #expect(plan != nil)
        #expect(abs(plan!.angle) < 1e-9)
        #expect(abs(plan!.side - 220 * 1.6) < 1e-6)          // 長辺 220 × 1.6
        #expect(abs(plan!.eyeMid.x - 200) < 1e-6)
        #expect(abs(plan!.target.x - plan!.side * 0.5) < 1e-6)
        #expect(abs(plan!.target.y - plan!.side * 0.65) < 1e-6)   // 上から 35% ＝ 下から 65%
    }

    @Test("傾いた目は角度が出る（右目が高い＝正の角度）")
    func tiltedEyes() {
        let plan = FaceAlignment.plan(leftEye: CGPoint(x: 150, y: 200),
                                      rightEye: CGPoint(x: 250, y: 300),
                                      pixelBox: box)
        #expect(plan != nil)
        #expect(abs(plan!.angle - atan2(100, 100)) < 1e-6)   // 45° ちょうどは許容
    }

    @Test("過大な傾き（>45°）・目が近すぎ・顔が小さすぎは nil（bbox 切り抜きへフォールバック）")
    func fallbackConditions() {
        // 65° 相当の傾き → 誤検出の可能性が高い。
        #expect(FaceAlignment.plan(leftEye: CGPoint(x: 150, y: 100),
                                   rightEye: CGPoint(x: 200, y: 250),
                                   pixelBox: box) == nil)
        // 目が同一点。
        #expect(FaceAlignment.plan(leftEye: CGPoint(x: 150, y: 200),
                                   rightEye: CGPoint(x: 151, y: 200),
                                   pixelBox: box) == nil)
        // 顔が小さすぎる（辺 16px 未満）。
        #expect(FaceAlignment.plan(leftEye: CGPoint(x: 4, y: 6),
                                   rightEye: CGPoint(x: 9, y: 6),
                                   pixelBox: CGRect(x: 2, y: 2, width: 8, height: 8)) == nil)
    }

    // MARK: - 名前の持ち越し（版上げ再スキャン・FaceStore）

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 1)
    }

    @Test("版上げ再スキャン: メンバー写真の重なりで名前が新クラスタへ戻る")
    func namesCarryOverAcrossRescan() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<5 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        let people = await store.peopleClusters(minFaces: 3)
        await store.rename(clusterID: people[0].clusterID, name: "山田太郎")

        // 版上げ: スナップショット → 全消去 → 再スキャン（同じ写真・埋め込みは変わった想定）。
        let snapshot = await store.namedClusterEntries()
        #expect(snapshot.count == 1)
        #expect(snapshot[0].memberRefKeys.count == 5)
        await store.reset()
        for i in 0..<5 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([0, 1, 0])])   // 新パイプラインの埋め込み
        }
        let remaining = await store.reapplyNames(snapshot)
        #expect(remaining.isEmpty)
        let after = await store.peopleClusters(minFaces: 3)
        #expect(after.first?.name == "山田太郎")
    }

    @Test("重なり不足（スキャン未進行）の名前は残り、後で再試行できる")
    func insufficientOverlapStaysPending() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<5 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        let people = await store.peopleClusters(minFaces: 3)
        await store.rename(clusterID: people[0].clusterID, name: "山田太郎")
        let snapshot = await store.namedClusterEntries()
        await store.reset()
        // まだ 1 枚しか再スキャンされていない（必要重なり = max(2, 5/5) = 2 に届かない）。
        await store.recordScan(refKey: "L-a0", faces: [signal([0, 1, 0])])
        let remaining = await store.reapplyNames(snapshot)
        #expect(remaining.count == 1)
        // 追加で 1 枚進めば適用される。
        await store.recordScan(refKey: "L-a1", faces: [signal([0, 1, 0])])
        let remaining2 = await store.reapplyNames(remaining)
        #expect(remaining2.isEmpty)
    }
}
