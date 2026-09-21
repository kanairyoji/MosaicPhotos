import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 連写・服装の連結と重心の凍結を、**永続層を通して**確かめる（ADR-210/211/212）。
/// 純ロジック側の判断は各 Suite で固定済みなので、ここは配線（渡し忘れ・順序）を見る。
@Suite("連結と重心の凍結（配線）", .serialized)
struct LinkingIntegrationTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func signal(_ v: [Float], quality: Float, box: CGRect, at offset: TimeInterval,
                        torso: [Float]? = nil) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: box, embedding: ClipMath.encodeHalf(v), quality: quality,
                           captureDate: base.addingTimeInterval(offset),
                           torsoEmbedding: torso.map { ClipMath.encodeHalf($0) })
    }

    private func box(_ x: Double) -> CGRect {
        CGRect(x: x, y: 0.4, width: 0.2, height: 0.2)
    }

    // MARK: - 連写（ADR-211）

    /// 連写の真ん中の 1 枚だけ、顔が埋め込みでは届かない（別方向）。位置は同じ。
    @Test("連写の同じ位置にある顔が、埋め込みでは届かなくても人物に入る")
    func burstLinkRescuesABlurredFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // まず人物を確立させる（連写の外で 6 枚）。
        for i in 0..<6 {
            await store.recordScan(refKey: "L-base\(i)",
                                   faces: [signal([1, 0, 0], quality: 0.9, box: box(0.1),
                                                  at: -3600 - Double(i))])
        }
        // 連写 3 枚: 真ん中はどの人物にも似ていない方向＋低品質＝普段なら未割当のまま。
        await store.recordScan(refKey: "L-b0",
                               faces: [signal([1, 0, 0], quality: 0.9, box: box(0.1), at: 0)])
        await store.recordScan(refKey: "L-b1",
                               faces: [signal([0, 0, 1], quality: 0.1, box: box(0.1), at: 0.4)])
        await store.recordScan(refKey: "L-b2",
                               faces: [signal([1, 0, 0], quality: 0.9, box: box(0.1), at: 0.8)])

        let beforeCount = await store.clusterCountsForTesting()[0]
        _ = await store.rebuildClusters()

        // ⚠️ 再クラスタは ID を再利用しない（ADR-187）ので、既知のメンバーから人物を引く。
        let person = await store.clusterIDForTesting(faceID: "L-b0#0")
        #expect(person != nil)
        let members = await store.facesForTesting(inCluster: person ?? -1)
        #expect(members.contains("L-b1#0"))
        // ⚠️ **重心は動かさない**（所属だけ）。寄与した顔の数は連写の前後で変わらない。
        #expect(await store.clusterCountsForTesting()[person ?? -1] == beforeCount)
        #expect(await store.contributingFaceIDsForTesting(inCluster: person ?? -1)
                    .contains("L-b1#0") == false)
        #expect(await store.linkSourceForTesting("L-b1#0") == "temporal")
    }

    /// 居合わせた 2 人の連写では、位置が入れ替わらない限り取り違えない。
    @Test("連写に 2 人居ても、それぞれの位置の人物に入る")
    func burstWithTwoPeopleKeepsThemApart() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-a\(i)", faces: [
                signal([1, 0, 0], quality: 0.9, box: box(0.1), at: -3600 - Double(i)),
                signal([0, 1, 0], quality: 0.9, box: box(0.7), at: -3600 - Double(i)),
            ])
        }
        await store.recordScan(refKey: "L-b0", faces: [
            signal([1, 0, 0], quality: 0.9, box: box(0.1), at: 0),
            signal([0, 1, 0], quality: 0.9, box: box(0.7), at: 0),
        ])
        await store.recordScan(refKey: "L-b1", faces: [
            signal([0, 0, 1], quality: 0.1, box: box(0.1), at: 0.4),
            signal([0, 0, 1], quality: 0.1, box: box(0.7), at: 0.4),
        ])
        _ = await store.rebuildClusters()

        let byPhoto = await store.clusterIDsByPhotoForTesting()
        let burst = (byPhoto["L-b1"] ?? []).filter { $0 >= 0 }
        // 同じ人物へ 2 つ入っていない（同一写真 cannot-link）。
        #expect(burst.count == Set(burst).count)
    }

    // MARK: - 服装（ADR-212）

    @Test("同じ場面で服が一致する顔が人物に入る（重心は動かさない）")
    func torsoLinkRescuesABlurredFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let shirt: [Float] = [0, 0, 1]
        for i in 0..<6 {
            await store.recordScan(
                refKey: "L-a\(i)",
                faces: [signal([1, 0, 0], quality: 0.9, box: box(0.1),
                               at: Double(i) * 60, torso: shirt)])
        }
        // 同じ場面・同じ服。位置は違う（連写では拾えない）。顔は**第2パスにも届かない**
        // （重心との cos ≈ 0.50 < secondPassThreshold 0.55）が、服の最低線 0.45 は超えている。
        await store.recordScan(
            refKey: "L-weak",
            faces: [signal([0.5, 0.866, 0], quality: 0.1, box: box(0.75),
                           at: 400, torso: shirt)])

        let beforeCount = await store.clusterCountsForTesting()[0]
        _ = await store.rebuildClusters()
        let person = await store.clusterIDForTesting(faceID: "L-a0#0")
        #expect(person != nil)
        #expect(await store.facesForTesting(inCluster: person ?? -1).contains("L-weak#0"))
        #expect(await store.clusterCountsForTesting()[person ?? -1] == beforeCount)
        #expect(await store.linkSourceForTesting("L-weak#0") == "torso")
    }

    /// ⚠️ **胴体だけで人物は作らない**。顔が確立していない場面では何も起きない。
    @Test("その場面に顔で確立した人物が居なければ、服が同じでも繋がない")
    func torsoNeverCreatesAPerson() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let shirt: [Float] = [0, 0, 1]
        await store.recordScan(refKey: "L-x",
                               faces: [signal([1, 0, 0], quality: 0.1, box: box(0.1),
                                              at: 0, torso: shirt)])
        await store.recordScan(refKey: "L-y",
                               faces: [signal([0, 1, 0], quality: 0.1, box: box(0.7),
                                              at: 60, torso: shirt)])
        _ = await store.rebuildClusters()
        let digests = await store.faceDigestsForTesting()
        #expect(digests.allSatisfy { $0.clusterID < 0 })
    }

    // MARK: - 重心の凍結（ADR-210）

    @Test("再クラスタは各人物の散らばりを測って記録する")
    func rebuildRecordsSpread() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<8 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.02, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        _ = await store.rebuildClusters()
        let person = await store.clusterIDForTesting(faceID: "L-a0#0") ?? -1
        let spread = (await store.spreadsForTesting()[person]) ?? nil
        #expect(spread != nil)
        #expect(spread.map { $0 < 0.1 } == true)   // 同じ人なので散らばりは小さい
    }

    /// 散らばりすぎた人物は、次のスキャンで**所属だけ**受け取る（重心が動かない）。
    @Test("散らばった人物の重心は、次のスキャンで動かない")
    func driftedClusterStopsGrowing() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<12 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        let before = await store.clusterCountsForTesting()[0]
        // 「過半のメンバーが、今のしきい値ではもう入らない」状態を直に作る。
        await store.setClusterSpreadForTesting(clusterID: 0, spread: 0.95)

        await store.recordScan(refKey: "L-new",
                               faces: [signal([1, 0.01, 0], quality: 0.9, box: box(0.1),
                                              at: 999_999)])
        #expect(await store.facesForTesting(inCluster: 0).contains("L-new#0"))
        #expect(await store.clusterCountsForTesting()[0] == before)   // 重心は据え置き
        #expect(await store.contributingFaceIDsForTesting(inCluster: 0).contains("L-new#0") == false)
    }

    @Test("散らばりが小さい人物は普通に育つ（凍結しない）")
    func healthyClusterKeepsGrowing() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<12 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.9,
                                                  box: box(0.1), at: Double(i) * 3600)])
        }
        _ = await store.rebuildClusters()
        let person = await store.clusterIDForTesting(faceID: "L-a0#0") ?? -1
        let before = await store.clusterCountsForTesting()[person] ?? 0
        await store.recordScan(refKey: "L-new",
                               faces: [signal([1, 0.01, 0], quality: 0.9, box: box(0.1),
                                              at: 999_999)])
        #expect(await store.clusterCountsForTesting()[person] == before + 1)
    }
}
