import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 人物アルバムの長押し操作（「この人ではない」「別の人」）は、**画面に出ている人物**を対象にする。
///
/// ⚠️ 実フィードバック（8/31）「長押しで選んでも別の人にならない。変化がない」。
/// 原因は対象の解き方で、`clusterID == 主クラスタ` で顔を引いていた。2 階層の束ね（ADR-61）では
/// 同じ人物の写真が**別の時期クラスタ**に入っているため、一致 0 件＝何も起きなかった。
/// 顔ハイライトは最初から束ね全体を見ていたので「黄枠は出るのに外せない」形になっていた。
@Suite("束ねた人物への写真操作", .serialized)
struct PhotoActionsOnGroupedPersonTests {

    private func signal(_ v: [Float], quality: Float = 0.9) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// 束ねた人物（A＝主・B＝別の時期）と、B にだけ写っている写真 "L-b0" を持つストア。
    private func makeGrouped() async -> (store: FaceStore, primary: Int, secondary: Int) {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        let a = map.first { $0.value.contains("L-a0") }?.key ?? -1
        let b = map.first { $0.value.contains("L-b0") }?.key ?? -1
        await store.linkClusters([a, b])
        return (store, a, b)
    }

    @Test("「この人ではない」は、別の時期クラスタに居る写真にも効く")
    func removeWorksAcrossLinkedClusters() async {
        let (store, primary, secondary) = await makeGrouped()
        #expect(primary >= 0 && secondary >= 0 && primary != secondary, "fixture: 2 クラスタになっていない")
        #expect(await store.linkedClusterIDs(primary: primary).count == 2, "fixture: 束ねられていない")
        // 前提: 対象の写真は**主クラスタには居ない**（ここが以前の取りこぼし）。
        #expect(await store.memberRefKeysByCluster()[primary]?.contains("L-b0") != true,
                "fixture: 写真が主クラスタに入ってしまっている")

        let removed = await store.removePhoto(refKey: "L-b0", from: primary)
        #expect(removed == 1, "束ねた人物の写真を外せていない（押しても何も起きない状態）")
        let after = await store.memberRefKeysByCluster()
        let linked = Set(await store.linkedClusterIDs(primary: primary))
        #expect(!linked.contains { after[$0]?.contains("L-b0") == true },
                "外したのに、まだこの人物の写真として残っている")
    }

    @Test("「別の人」も、別の時期クラスタに居る写真を移せる")
    func moveWorksAcrossLinkedClusters() async {
        let (store, primary, secondary) = await makeGrouped()
        #expect(secondary >= 0)
        // 移動先の人物（束ねと無関係）を用意する。
        await store.recordScan(refKey: "L-c0", faces: [signal([0, 0, 1])])
        let target = await store.memberRefKeysByCluster().first { $0.value.contains("L-c0") }?.key ?? -1
        #expect(target >= 0 && target != primary && target != secondary, "fixture: 移動先が作れていない")

        let moved = await store.movePhoto(refKey: "L-b0", from: primary, to: target)
        #expect(moved == 1, "束ねた人物の写真を移せていない")
        #expect(await store.memberRefKeysByCluster()[target]?.contains("L-b0") == true,
                "移動先に入っていない")
    }

    @Test("束ねていない人物では従来どおり（主クラスタの写真だけが対象）")
    func plainPersonUnchanged() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        await store.recordScan(refKey: "L-z0", faces: [signal([0, 1, 0])])
        let map = await store.memberRefKeysByCluster()
        let a = map.first { $0.value.contains("L-a0") }?.key ?? -1
        #expect(a >= 0)
        #expect(await store.removePhoto(refKey: "L-a1", from: a) == 1)
        #expect(await store.removePhoto(refKey: "L-z0", from: a) == 0,
                "別人の写真まで外してはいけない")
    }
}
