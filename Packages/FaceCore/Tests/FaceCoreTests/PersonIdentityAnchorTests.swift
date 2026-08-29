import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 人物の同一性が再クラスタで入れ替わらないこと（ADR-130）。
///
/// 実害: 「私」の顔を認識していたアルバムが、いつの間にか**丸ごと娘の写真**になり、
/// 自分の顔は "People 9" として別人に追い出されていた。原因は再クラスタの種の作り方で、
/// (1) 代表写真がアンカーでなかった (2) 名前を付けただけの人物はアンカーが 0 で、
/// 重心の向きだけが手掛かりだった (3) 確立した人物が種になる瞬間 count=1 の
/// 「生まれたてのクラスタ」扱いになり、サイズ適応マージンで本人の顔すら入れなかった。
///
/// ⚠️ ここでの検証は「重心が別人へ寄っていても、ユーザーの表明（代表写真/名前/確認）が
/// 人物を引き戻すこと」。重心を差し替えて**ドリフト済みの状態**を明示的に作る。
@Suite("Person identity anchors survive rebuild", .serialized)
struct PersonIdentityAnchorTests {

    private func signal(_ v: [Float], quality: Float = 1) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// A（自分・6 枚）と B（別人・12 枚＝多数派）の 2 人。
    private func makeStore() async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<6 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])])
        }
        for i in 0..<12 {
            await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.01])])
        }
        return store
    }

    /// A の顔が入っているクラスタ ID（最も A の写真を多く含むもの）。
    private func clusterOfA(_ store: FaceStore) async -> Int? {
        let members = await store.memberRefKeysByCluster()
        return members.max { lhs, rhs in
            lhs.value.filter { $0.hasPrefix("L-a") }.count
                < rhs.value.filter { $0.hasPrefix("L-a") }.count
        }?.key
    }

    @Test("代表写真に選んだ顔は、重心が別人へ寄っていても人物を引き戻す")
    func coverAnchorPullsIdentityBack() async {
        let store = await makeStore()
        guard let aID = await clusterOfA(store),
              let cover = await store.facesForCluster(clusterID: aID)
                .first(where: { $0.refKey.hasPrefix("L-a") }) else {
            Issue.record("fixture: A のクラスタが作れていない"); return
        }
        // fixture の前提を assert する（空でも通る検証にしない）。
        let before = await store.memberRefKeysByCluster()[aID] ?? []
        #expect(before.filter { $0.hasPrefix("L-a") }.count >= 5)
        #expect(before.filter { $0.hasPrefix("L-b") }.isEmpty)

        // ユーザーが代表写真を選ぶ＝「この人はこの顔」。
        await store.setCover(clusterID: aID, faceID: cover.faceID)
        // 重心が別人（B）の向きへ寄ってしまった状態を作る。
        await store.setClusterSumForTesting(clusterID: aID, vector: [0, 1, 0])

        _ = await store.rebuildClusters()

        let after = await store.memberRefKeysByCluster()[aID] ?? []
        // 代表写真の顔はこの人物に固定される。
        #expect(after.contains(cover.refKey))
        // 別人（B）に乗っ取られていない。
        #expect(after.filter { $0.hasPrefix("L-b") }.isEmpty)
        // 自分の写真が追い出されていない。
        #expect(after.filter { $0.hasPrefix("L-a") }.count >= 5)
    }

    @Test("名前を付けた人物は、重心が別人へ寄っていても名前ごと入れ替わらない")
    func namedPersonKeepsItsFaces() async {
        let store = await makeStore()
        guard let aID = await clusterOfA(store) else {
            Issue.record("fixture: A のクラスタが作れていない"); return
        }
        await store.rename(clusterID: aID, name: "私")
        await store.setClusterSumForTesting(clusterID: aID, vector: [0, 1, 0])

        _ = await store.rebuildClusters()

        let names = await store.namesByClusterForTesting()
        guard let mine = names.first(where: { $0.value == "私" })?.key else {
            Issue.record("名前が消えた"); return
        }
        // 名前を付けた時点でアンカーが立つので、人物は**同じクラスタのまま**動かない
        // （名前が別 ID へ逃げる＝アンカーが効いていない）。
        #expect(mine == aID)
        let members = await store.memberRefKeysByCluster()[mine] ?? []
        #expect(members.filter { $0.hasPrefix("L-a") }.count >= 5)
        #expect(members.filter { $0.hasPrefix("L-b") }.isEmpty)
    }

    @Test("アンカーの無い命名済み人物（旧データ）は、顔が移った先へ名前も移る")
    func nameFollowsItsMembers() async {
        let store = await makeStore()
        guard let aID = await clusterOfA(store) else {
            Issue.record("fixture: A のクラスタが作れていない"); return
        }
        await store.rename(clusterID: aID, name: "私")
        // ADR-130 以前のデータ（名前だけでアンカーが無い）を再現し、重心を別人へ寄せる。
        await store.clearAnchorsForTesting(clusterID: aID)
        await store.setClusterSumForTesting(clusterID: aID, vector: [0, 1, 0])

        _ = await store.rebuildClusters()

        let names = await store.namesByClusterForTesting()
        guard let mine = names.first(where: { $0.value == "私" })?.key else {
            Issue.record("名前が消えた"); return
        }
        let members = await store.memberRefKeysByCluster()[mine] ?? []
        // 名前は「人」に付いている: A の顔が移った先が「私」になり、B のアルバムにはならない。
        #expect(members.filter { $0.hasPrefix("L-a") }.count >= 5)
        #expect(members.filter { $0.hasPrefix("L-b") }.isEmpty)
    }
}
