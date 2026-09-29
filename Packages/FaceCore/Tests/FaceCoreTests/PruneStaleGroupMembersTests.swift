import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 「もう誰も指していないメンバーを記録から落とす」掃除（ADR-235）。
///
/// ⚠️⚠️ この関数は**利用者が作ったもの（家族グループの構成）を消す**ので、
/// 「落とす条件」を間違えると黙って失う。落とした後は表示も監査も静かになるので、
/// 誰も気づけない——だから条件を全部ここで固定する。
///
/// ⚠️ 実際に埋め込みかけた形（レビューで気づいた）: 生存クラスタを `allClusters()` から
/// 取っていた。あれは fetch の失敗を `[]` に畳むので、**読めなかった瞬間に全メンバーが
/// 「もう居ない」と判定され、記録ごと消えて save される**。
/// この会で 2 度目の「失敗を『1 つも無い』と読む」——`peopleGroupMemberClusterIDs()` でも
/// 同じ形を踏んだ（⚠️ **あちらは直してある**。ここだけ残っていた）。
@Suite("グループメンバーの掃除は、失う側へ倒さない", .serialized)
struct PruneStaleGroupMembersTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// A（4 枚）と B（3 枚）が別クラスタになっているストア。
    private func makeStore() async -> (store: FaceStore, a: Int, b: Int) {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        let a = map.first { $0.value.contains("L-a0") }?.key ?? -1
        let b = map.first { $0.value.contains("L-b0") }?.key ?? -1
        return (store, a, b)
    }

    private func members(_ store: FaceStore, _ id: UUID) async -> [Int] {
        await store.allPeopleGroupRecords().first { $0.id == id }?.memberClusterIDs ?? []
    }

    @Test("居なくなったメンバーだけを落とし、実在するメンバーは残す")
    func dropsOnlyTheMembersThatNoLongerExist() async {
        let (store, a, b) = await makeStore()
        #expect(a >= 0 && b >= 0 && a != b, "fixture: 2 人になっていない")
        // 999 は一度も存在しないクラスタ（＝再クラスタで消えたメンバーの代わり）。
        let group = await store.createPeopleGroup(name: "家族", memberClusterIDs: [a, b, 999])

        let dropped = await store.pruneStaleGroupMembers()

        #expect(dropped.map(\.dropped) == [1], "落とした件数が 1 件になっていない: \(dropped)")
        #expect(await members(store, group).sorted() == [a, b].sorted(),
                "実在するメンバーまで落としている（家族から人が消える）")
    }

    @Test("落とすものが無ければ、記録に触らない")
    func doesNothingWhenEverybodyIsStillThere() async {
        let (store, a, b) = await makeStore()
        let group = await store.createPeopleGroup(name: "家族", memberClusterIDs: [a, b])

        let dropped = await store.pruneStaleGroupMembers()

        #expect(dropped.isEmpty, "落とすものが無いのに触っている: \(dropped)")
        #expect(await members(store, group).sorted() == [a, b].sorted())
    }

    /// ⚠️⚠️ **ここが本丸**。クラスタが 1 つも読めない状態（fetch 失敗・世代の切り替え直後）で
    /// 掃除を走らせると、**全グループの全メンバーが消える**。
    /// 「読めなかった」と「1 つも無い」は違う、を固定する。
    @Test("クラスタが 0 件のときは、1 人も落とさない")
    func keepsEveryMemberWhenThereAreNoClustersAtAll() async {
        let store = FaceStore(isStoredInMemoryOnly: true)   // 顔を 1 つも記録していない
        let group = await store.createPeopleGroup(name: "家族", memberClusterIDs: [1, 2, 3])
        #expect(await members(store, group) == [1, 2, 3], "fixture: メンバーが入っていない")

        let dropped = await store.pruneStaleGroupMembers()

        #expect(dropped.isEmpty, "クラスタ 0 件を『全員もう居ない』と読んでいる: \(dropped)")
        #expect(await members(store, group) == [1, 2, 3], """
            クラスタが読めない/まだ無い状態でメンバーを消した。
            世代の切り替え中なら、持ち越しがこれから埋める——そこで消すと本当に失う。
            """)
    }
}
