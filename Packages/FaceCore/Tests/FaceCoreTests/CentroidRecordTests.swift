import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// **「重心に寄与したか」は事実の記録**（ADR-210）。
///
/// ⚠️ 実ライブラリでは顔の約半数が品質フロア未満で、重心には入らない。それでも再クラスタの
/// 書き戻しは「留めた顔はすべて寄与した」と記録していたため、30 枚の人物で `count == 4` なのに
/// 30 行が「寄与した」と言う状態になっていた。あとで数枚外すと `count` が尽き、
/// **人物が丸ごと消える**（残った顔は存在しない ID を指す）。
@Suite("重心の寄与の記録（ADR-210）", .serialized)
struct CentroidRecordTests {

    private func signal(_ v: [Float], quality: Float,
                        box: CGRect = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2))
        -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: box, embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// 高品質 6 枚＋低品質 10 枚の「名前を付けた人物」を作る。
    private func makeNamedPerson() async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-hi\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.9)])
        }
        // 昼の線（0.40）未満＝第2パスで membership だけ入る顔。名前付き人物の重心を作り直す線
        // （0.20・ADR-221）よりも下に置く＝夜の作り直しでも重心へは入らない。
        for i in 0..<10 {
            await store.recordScan(refKey: "L-lo\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0.02], quality: 0.1)])
        }
        await store.rename(clusterID: 0, name: "私")
        return store
    }

    /// ⚠️ **この不一致こそが実害の入口**。count と「寄与した」と言う行数が食い違うと、
    /// 付け替えのたびに引き算がずれていく。
    @Test("再クラスタの書き戻しは、実際に足した顔だけを『寄与した』と記録する")
    func writeBackRecordsOnlyWhatWasActuallyAdded() async {
        let store = await makeNamedPerson()
        _ = await store.rebuildClusters()

        let counts = await store.clusterCountsForTesting()
        let contributing = await store.contributingFaceIDsForTesting(inCluster: 0)
        let members = await store.facesForTesting(inCluster: 0)

        #expect(members.count == 16)            // 低品質の顔も人物には入る（表示は減らない）
        #expect(counts[0] == 6)                 // 重心を作ったのは高品質の 6 枚だけ
        #expect(contributing.count == counts[0])   // ← 旧実装はここで 16 になっていた
        #expect(contributing.allSatisfy { $0.hasPrefix("L-hi") })
    }

    /// 上のずれが残っていると、数枚外したところで `count` が尽きて人物が消える。
    @Test("低品質の顔を何枚外しても、人物は消えない")
    func removingLowQualityFacesNeverDeletesThePerson() async {
        let store = await makeNamedPerson()
        _ = await store.rebuildClusters()

        let lowQuality = await store.facesForTesting(inCluster: 0).filter { $0.hasPrefix("L-lo") }
        for faceID in lowQuality.prefix(8) {
            await store.reassignFace(faceID: faceID, toClusterID: nil)
        }
        let counts = await store.clusterCountsForTesting()
        #expect(counts[0] == 6)   // 重心は 1 つも減らない（そもそも入っていなかった）
        #expect(await store.namesByClusterForTesting()[0] == "私")
    }

    /// 監査は「見つけて言う」だけ。壊れた状態を作ったら必ず気づけることを固定する。
    @Test("重心がずれていれば監査が見つける")
    func auditFindsACorruptedCentroid() async {
        let store = await makeNamedPerson()
        _ = await store.rebuildClusters()
        #expect(await store.centroidDriftFindingsForTesting().isEmpty)

        // 別人の方向へ引きずられた重心を作る（実機では付け替えの取りこぼしで起こる形）。
        await store.setClusterSumForTesting(clusterID: 0, vector: [0, 0, 1])
        let findings = await store.centroidDriftFindingsForTesting()
        #expect(findings.map(\.kind) == [.sumDrift])
    }

    /// 再クラスタは**作り直し**なので、2 回続けて回しても答えが変わってはいけない。
    /// 変わるなら、どこかに前回の結果を参照する自己参照が残っている（ADR-210 の直した形）。
    @Test("再クラスタは冪等（2 回回しても割り当てが動かない）")
    func rebuildIsIdempotent() async {
        let store = await makeNamedPerson()
        _ = await store.rebuildClusters()
        let first = await store.faceDigestsForTesting().sorted { $0.faceID < $1.faceID }
        let firstCounts = await store.clusterCountsForTesting()

        let second = await store.rebuildClusters()
        let after = await store.faceDigestsForTesting().sorted { $0.faceID < $1.faceID }
        #expect(second.moved == 0)
        #expect(first.map(\.clusterID) == after.map(\.clusterID))
        #expect(firstCounts == (await store.clusterCountsForTesting()))
    }

    /// ⚠️ 確認顔も「ユーザーの表明」（ADR-132）。名前も代表写真も付けず、レビューで
    /// 「はい」とだけ答えて育てた人物は、行の保護対象から漏れていた（ADR-210）。
    @Test("確認顔だけの無名クラスタは、重心を作る顔が出ていっても行ごと消えない")
    func confirmedOnlyClusterIsProtected() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 重心を作るのは 1 枚だけ。残りは第2パス（membership のみ）で入る低品質の顔。
        await store.recordScan(refKey: "L-hi", faces: [signal([1, 0, 0], quality: 0.9)])
        for i in 0..<3 {
            await store.recordScan(refKey: "L-lo\(i)",
                                   faces: [signal([1, Float(i) * 0.01, 0], quality: 0.2)])
        }
        await store.confirmFace(faceID: "L-hi#0")   // 名前も代表写真も付けない
        #expect(await store.clusterCountsForTesting()[0] == 1)

        // 唯一の寄与顔を外す＝「最後の 1 顔」の経路に入る。
        await store.reassignFace(faceID: "L-hi#0", toClusterID: nil)

        // ⚠️ 行が消えると、membership だけで入っていた 3 枚が孤児になる。
        #expect(await store.clusterExistsForTesting(0))
        #expect(await store.facesForTesting(inCluster: 0).count == 3)
    }

    /// 同一写真 cannot-link（ADR-54）は、連写・服装の連結を足したあとも破れてはいけない。
    @Test("1 枚の写真に同じ人物が 2 回入らない（連結を足したあとも）")
    func cannotLinkHoldsAfterRebuild() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 2 人が一緒に写っている連写。ぶれた顔（低品質）も混ぜる。
        for i in 0..<6 {
            await store.recordScan(refKey: "L-burst\(i)", faces: [
                signal([1, 0, 0], quality: i % 2 == 0 ? 0.9 : 0.2,
                       box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
                signal([0, 1, 0], quality: i % 2 == 0 ? 0.9 : 0.2,
                       box: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.2)),
            ])
        }
        _ = await store.rebuildClusters()
        let byPhoto = await store.clusterIDsByPhotoForTesting()
        for (refKey, clusterIDs) in byPhoto {
            let assigned = clusterIDs.filter { $0 >= 0 }
            #expect(assigned.count == Set(assigned).count, "\(refKey) に同じ人物が 2 回")
        }
    }
}
