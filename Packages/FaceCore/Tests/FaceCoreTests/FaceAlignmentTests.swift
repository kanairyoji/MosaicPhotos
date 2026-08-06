import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

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

    // MARK: - ArcFace 5 点整列（ADR-70）

    @Test("相似変換: テンプレート自身へは恒等、回転・拡大した点群からは元の変換を復元する")
    func similarityRecovers() {
        let template = FaceAlignment.arcFaceTemplate112
        // 恒等: 同じ点群 → ほぼ単位行列。
        let identity = FaceAlignment.similarityTransform(from: template, to: template)
        #expect(identity != nil)
        if let t = identity {
            #expect(abs(t.a - 1) < 1e-6 && abs(t.b) < 1e-6 && abs(t.tx) < 1e-4 && abs(t.ty) < 1e-4)
        }
        // 既知の相似変換（30° 回転・2 倍・平行移動）を適用した点群から復元できる。
        let known = CGAffineTransform(translationX: 40, y: -25)
            .rotated(by: .pi / 6).scaledBy(x: 2, y: 2)
        let moved = template.map { $0.applying(known) }
        guard let recovered = FaceAlignment.similarityTransform(from: moved, to: template) else {
            Issue.record("recovered == nil"); return
        }
        for p in moved {
            let q = p.applying(recovered)
            // moved を戻すと template に一致する。
            let idx = moved.firstIndex(of: p)!
            #expect(abs(q.x - template[idx].x) < 1e-3)
            #expect(abs(q.y - template[idx].y) < 1e-3)
        }
    }

    @Test("相似変換: 最小二乗＝ノイズがあってもテンプレート近傍へ写す")
    func similarityLeastSquares() {
        let template = FaceAlignment.arcFaceTemplate112
        // 各点に ±1px のノイズを加えた点群（誤差つき検出の模擬・決定的な擬似ノイズ）。
        let noisy = template.enumerated().map { i, p in
            CGPoint(x: p.x + (i % 2 == 0 ? 1.0 : -1.0), y: p.y + (i % 3 == 0 ? -1.0 : 1.0))
        }
        guard let t = FaceAlignment.similarityTransform(from: noisy, to: template) else {
            Issue.record("t == nil"); return
        }
        for (p, target) in zip(noisy, template) {
            let q = p.applying(t)
            #expect(abs(q.x - target.x) < 2)   // 最小二乗なので誤差は残るが暴れない
            #expect(abs(q.y - target.y) < 2)
        }
    }

    @Test("arcFaceTransform: 退化した点群・過大な回転は nil（bbox へフォールバック）")
    func arcFaceRejectsDegenerate() {
        // 全点ほぼ同一（誤検出）。
        let degenerate = FaceAlignment.FivePoints(
            leftEye: CGPoint(x: 10, y: 10), rightEye: CGPoint(x: 10.001, y: 10),
            nose: CGPoint(x: 10, y: 10.001), mouthLeft: CGPoint(x: 10, y: 10),
            mouthRight: CGPoint(x: 10.001, y: 10.001))
        #expect(FaceAlignment.arcFaceTransform(points: degenerate) == nil)

        // 90° 回転（横倒しの誤ランドマーク）→ 拒否。
        let quarter = CGAffineTransform(rotationAngle: .pi / 2)
        let rotated = FaceAlignment.arcFaceTemplate112.map { $0.applying(quarter) }
        let points = FaceAlignment.FivePoints(
            leftEye: rotated[0], rightEye: rotated[1], nose: rotated[2],
            mouthLeft: rotated[3], mouthRight: rotated[4])
        #expect(FaceAlignment.arcFaceTransform(points: points) == nil)

        // 正常（テンプレートの 1.5 倍・10° 回転）→ 変換が返る。
        let ok = CGAffineTransform(rotationAngle: .pi / 18).scaledBy(x: 1.5, y: 1.5)
        let normal = FaceAlignment.arcFaceTemplate112.map { $0.applying(ok) }
        let okPoints = FaceAlignment.FivePoints(
            leftEye: normal[0], rightEye: normal[1], nose: normal[2],
            mouthLeft: normal[3], mouthRight: normal[4])
        #expect(FaceAlignment.arcFaceTransform(points: okPoints) != nil)
    }
}
