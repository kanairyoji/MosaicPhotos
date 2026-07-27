import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// 顔情報の拡充（face-info-expansion）: 品質ゲート（横顔/傾き/目閉じ）・サイズ閾値・
/// 品質フロア 0.40・笑顔による代表顔選択。
@Suite("FaceInfoExpansion (quality gate + smile cover)", .serialized)
struct FaceInfoExpansionTests {

    // MARK: - FaceQualityGate（純ロジック）

    @Test("横顔（|yaw|≥30°）は品質がフロア未満へキャップされる")
    func profileCapsQuality() {
        let q = FaceQualityGate.adjustedQuality(quality: 0.9, yaw: 0.6, roll: nil, eyesClosed: nil)
        #expect(q == FaceQualityGate.profileCap)
        // 正面（yaw 小）は減衰しない。
        #expect(FaceQualityGate.adjustedQuality(quality: 0.9, yaw: 0.1, roll: nil, eyesClosed: nil) == 0.9)
        // yaw 不明（nil）は減衰しない（フォールバック検出でも動く）。
        #expect(FaceQualityGate.adjustedQuality(quality: 0.9, yaw: nil, roll: nil, eyesClosed: nil) == 0.9)
    }

    @Test("大きな傾き（|roll|≥45°）もキャップ・目閉じは係数減衰")
    func rollAndEyesClosed() {
        #expect(FaceQualityGate.adjustedQuality(quality: 0.9, yaw: nil, roll: 1.0, eyesClosed: nil)
                == FaceQualityGate.profileCap)
        let closed = FaceQualityGate.adjustedQuality(quality: 0.8, yaw: nil, roll: nil, eyesClosed: true)
        #expect(abs(closed - 0.8 * FaceQualityGate.eyesClosedFactor) < 1e-6)
        #expect(FaceQualityGate.adjustedQuality(quality: 0.8, yaw: nil, roll: nil, eyesClosed: false) == 0.8)
    }

    @Test("顔サイズ閾値はクラウドの方が大きい（低解像度サムネ対策）")
    func minFaceSide() {
        #expect(FaceQualityGate.minFaceSide(isCloud: true) > FaceQualityGate.minFaceSide(isCloud: false))
        #expect(FaceQualityGate.minFaceSide(isCloud: false) == 0.05)
        #expect(FaceQualityGate.minFaceSide(isCloud: true) == 0.15)
    }

    // MARK: - 品質フロア 0.40（FaceStore 経由）

    @Test("フロア未満（品質0.3）の顔はクラスタへ入らない（記録は残る）")
    func floorKeepsLowQualityOut() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
            DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                               embedding: ClipMath.encodeHalf(v), quality: quality)
        }
        for i in 0..<3 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0], quality: 1)])
        }
        // 同じ顔でも品質 0.3（< 0.40）は未割当＝クラスタの顔数が増えない。
        await store.recordScan(refKey: "L-blurry", faces: [signal([1, 0, 0], quality: 0.3)])
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1)
        #expect(people.first?.count == 3)   // blurry は含まれない
        // 記録自体は残る（顔数・枠表示用）。
        #expect(await store.scannedCount() == 4)
    }

    // MARK: - 笑顔フラグと代表顔の自動選択

    @Test("代表顔の自動選択は笑顔＋高品質＋大きい顔を優先する")
    func coverPrefersSmile() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        func signal(quality: Float, smile: Bool?, size: CGFloat = 0.3) -> DetectedFaceSignal {
            DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: size, height: size),
                               embedding: ClipMath.encodeHalf([1, 0, 0]), quality: quality,
                               hasSmile: smile)
        }
        // 同品質なら笑顔が勝つ（L-smile が代表になる）。
        await store.recordScan(refKey: "L-plain", faces: [signal(quality: 0.8, smile: false)])
        await store.recordScan(refKey: "L-smile", faces: [signal(quality: 0.8, smile: true)])
        await store.recordScan(refKey: "L-third", faces: [signal(quality: 0.8, smile: nil)])
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.first?.coverRefKey == "L-smile")
    }

    @Test("品質差が大きければ笑顔加点（0.3）より品質が勝つ")
    func qualityBeatsSmallSmileBonus() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        func signal(quality: Float, smile: Bool?) -> DetectedFaceSignal {
            DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                               embedding: ClipMath.encodeHalf([1, 0, 0]), quality: quality,
                               hasSmile: smile)
        }
        await store.recordScan(refKey: "L-sharp", faces: [signal(quality: 1.0, smile: false)])
        await store.recordScan(refKey: "L-smile", faces: [signal(quality: 0.5, smile: true)])
        await store.recordScan(refKey: "L-mid", faces: [signal(quality: 0.9, smile: nil)])
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.first?.coverRefKey == "L-sharp")
    }
}
