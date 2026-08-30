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

    @Test("命名済み人物のメンバーは、機械の都合（別クラスタの成長）で外へ出ない")
    func namedPersonKeepsMembersAcrossRebuild() async {
        // ⚠️ 4 次元。「本人に入ったあとで、別クラスタの方が近くなった顔」を作る
        // ——名前を付けたアルバムが、機械の都合（後から育った他人）で割られないことを見る。
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<10 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0, 0])])
        }
        // 本人の少し外れた 1 枚（cos 0.62 で合流する）。
        // ⚠️ 品質を下げておく: 命名でアンカーになるのは代表顔（品質最良）で、全員同じ品質だと
        // **どれがアンカーになるか実行ごとに変わる**。この 1 枚がアンカーになると、
        // 後から来る別人 B が「アンカーに似ている」で本人へ合流してしまい fixture が壊れる
        // （実際に一括実行でだけ落ちた）。
        await store.recordScan(refKey: "L-a-edge", faces: [signal([0.62, 0, 0.785, 0], quality: 0.6)])
        guard let aID = await clusterOfA(store) else {
            Issue.record("fixture: A のクラスタが作れていない"); return
        }
        await store.rename(clusterID: aID, name: "私")
        // 後から別人 B（例: 娘）が育ち、こちらにも名前が付く。B の重心は「外れた 1 枚」に
        // 本人より近い（cos 0.86 対 0.68）＝再割り当てすれば B に取られる位置。
        for i in 0..<12 {
            await store.recordScan(refKey: "L-b\(i)", faces: [signal([0.30, Float(i) * 0.004, 0.86, 0.41])])
        }
        let bID = await store.memberRefKeysByCluster()
            .first { $0.key != aID && $0.value.contains("L-b0") }?.key ?? -1
        #expect(bID >= 0)
        await store.rename(clusterID: bID, name: "娘")
        let before = await store.memberRefKeysByCluster()[aID] ?? []
        // fixture の前提を assert する。
        #expect(before.contains("L-a-edge"))
        #expect(before.filter { $0.hasPrefix("L-b") }.isEmpty)

        _ = await store.rebuildClusters()

        let after = await store.memberRefKeysByCluster()[aID] ?? []
        // 名前を付けた人物の構成は、ユーザーが何も言っていない限り変わらない。
        #expect(after.contains("L-a-edge"))
        #expect(after.filter { $0.hasPrefix("L-a") }.count == before.filter { $0.hasPrefix("L-a") }.count)
    }

    @Test("ユーザーが「この人ではない」と外した顔と同じ人物は、再クラスタで留めない")
    func userCorrectionEjectsMatchingFaces() async {
        // ⚠️ 4 次元で作る。3 次元だと「クラスタに入れるほど近い別人」を作ると、その別人が
        // 本人とも負例しきい値（0.55）を超えて似てしまい、負例が本人まで巻き込む
        // ＝ fixture の幾何が非現実的になる。次元を足して cos を独立に置く。
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<10 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0, 0])])
        }
        // 別人 X: 本人とは cos 0.52（合流はするが「同一人物」判定 0.55 は下回る）。
        // X0 と X1 は互いに cos ≈ 0.99（＝同じ人の 2 枚）。
        // ⚠️ 品質を下げる: 命名でアンカーになるのは代表顔（品質最良）で、混入した顔と本人の顔が
        // **同点**だと、混入の方がアンカーになる回がある。そうなると (1) 混入は確認顔として
        // 固定され (2) 負例の照合が本人の重心ではなく混入の向きで行われるため、
        // 「指摘した顔と同一人物を留めない」が成立しない——実行のたびに落ちたり通ったりする
        // （CI でだけ落ちた原因がこれ）。
        await store.recordScan(refKey: "L-x0", faces: [signal([0.52, 0, 0.854, 0], quality: 0.7)])
        await store.recordScan(refKey: "L-x1", faces: [signal([0.52, 0, 0.841, 0.148], quality: 0.7)])
        guard let aID = await clusterOfA(store) else {
            Issue.record("fixture: A のクラスタが作れていない"); return
        }
        await store.rename(clusterID: aID, name: "私")
        // ユーザーは本人の顔を代表に選んでいる、という状態を**明示的に**作る（同点に頼らない）。
        if let own = await store.facesForCluster(clusterID: aID).first(where: { $0.refKey == "L-a0" }) {
            await store.setCover(clusterID: aID, faceID: own.faceID)
        }
        let members = await store.memberRefKeysByCluster()[aID] ?? []
        // fixture の前提: 混入 2 枚とも「私」に入っている（ここが空だと何も検証していない）。
        #expect(members.contains("L-x0"))
        #expect(members.contains("L-x1"))

        // ユーザーが 1 枚だけ「この人ではない」と指摘する（負例として学習される）。
        _ = await store.removePhoto(refKey: "L-x0", from: aID)
        _ = await store.rebuildClusters()

        let after = await store.memberRefKeysByCluster()[aID] ?? []
        #expect(!after.contains("L-x0"))
        // 指摘は**同じ人物の別の顔**にも効く（1 枚ずつ全部指摘させない）。
        #expect(!after.contains("L-x1"))
        // 本人の顔は巻き込まれない。
        #expect(after.filter { $0.hasPrefix("L-a") }.count >= 9)
    }

    @Test("「まとめて確認」で統合した内容は、再クラスタ後も保たれる")
    func mergeSurvivesRebuild() async {
        // 同じ人が 2 つに割れている状況（cos 0.45＝しきい値 0.50 未満なので自動では合流しない）。
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0.45, 0.893, Float(i) * 0.005])]) }
        let before = await store.memberRefKeysByCluster()
        guard let aID = before.first(where: { $0.value.contains("L-a0") })?.key,
              let bID = before.first(where: { $0.value.contains("L-b0") })?.key, aID != bID else {
            Issue.record("fixture: 2 クラスタに割れていない"); return
        }

        // ユーザーが「同じ人」と答える（まとめて確認・1 対 1 の確認の実体）。
        #expect(await store.mergeClusters(from: bID, into: aID) == nil)
        let merged = await store.memberRefKeysByCluster()[aID] ?? []
        #expect(merged.contains("L-b0"), "前提: 統合できている")

        _ = await store.rebuildClusters()

        let after = await store.memberRefKeysByCluster()[aID] ?? []
        // 統合はユーザーの表明。夜の再クラスタで「なかったこと」になってはいけない。
        #expect(after.filter { $0.hasPrefix("L-b") }.count == 3, "統合が忘れられている")
        #expect(after.filter { $0.hasPrefix("L-a") }.count == 4)
    }

    @Test("束ねた人物（同一人物の別クラスタ）は、再クラスタで消えない")
    func groupingSurvivesRebuild() async {
        let store = await makeStore()
        let map = await store.memberRefKeysByCluster()
        guard let aID = map.first(where: { $0.value.contains("L-a0") })?.key,
              let bID = map.first(where: { $0.value.contains("L-b0") })?.key, aID != bID else {
            Issue.record("fixture: 2 クラスタになっていない"); return
        }
        // 成長で分かれた同じ人として束ねる（ADR-61）。融合はせず、両クラスタを 1 人物として扱う。
        await store.linkClusters([aID, bID])
        let linked = await store.memberRefKeys(forPerson: aID)
        #expect(linked.contains { $0.hasPrefix("L-b") }, "前提: 束ねが効いている")

        _ = await store.rebuildClusters()

        // 束ねの記録（personGroupID）はクラスタ行に載っている。行ごと消されると黙って忘れられる。
        let after = await store.memberRefKeys(forPerson: aID)
        #expect(after.contains { $0.hasPrefix("L-a") })
        #expect(after.contains { $0.hasPrefix("L-b") }, "束ねが忘れられている")
    }
}
