import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 家族が付けた人物名の取り込み（ADR-167）。
///
/// ⚠️ **自分が付けた名前は上書きしない**。名前は持ち主の判断で、受信のたびに相手の呼び方へ
/// 書き換わるのは事故に近い（「パパ」と「◯◯さん」が行き来する）。
@Suite("家族の人物名を取り込む", .serialized)
struct SharedNameImportTests {

    private func signal(_ v: [Float], name: String? = nil) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9,
                           personName: name)
    }

    @Test("無名の人物には名前が付く")
    func namesUnnamedPerson() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let batch = (0..<3).map { i in
            (refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0], name: "太郎")])
        }
        _ = await store.recordScans(batch)
        // 前提: 名前はまだ無い。
        let before = await store.peopleClusters(minFaces: 1)
        #expect(before.contains { $0.name?.isEmpty == false } == false, "fixture: 既に名前がある")

        let applied = await store.applySharedNames(batch)
        #expect(applied >= 1, "名前が 1 人も付いていない")
        let after = await store.peopleClusters(minFaces: 1)
        #expect(after.contains { $0.name == "太郎" }, "取り込んだ名前が反映されていない")
    }

    @Test("自分が付けた名前は上書きしない")
    func keepsOwnName() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let batch = (0..<3).map { i in
            (refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0], name: "パパ")])
        }
        _ = await store.recordScans(batch)
        let map = await store.memberRefKeysByCluster()
        let clusterID = map.first { $0.value.contains("L-a0") }?.key ?? -1
        #expect(clusterID >= 0)
        await store.rename(clusterID: clusterID, name: "お父さん")

        let applied = await store.applySharedNames(batch)
        #expect(applied == 0, "自分の名前を上書きしている")
        let after = await store.peopleClusters(minFaces: 1)
        #expect(after.contains { $0.name == "お父さん" }, "自分が付けた名前が消えた")
        #expect(after.contains { $0.name == "パパ" } == false)
    }

    @Test("名前が入っていなければ何も起きない（顔だけの共有）")
    func noNamesNoop() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let batch = (0..<3).map { i in
            (refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])])
        }
        _ = await store.recordScans(batch)
        #expect(await store.applySharedNames(batch) == 0)
    }

    @Test("同じ人物に別々の名前が来たら多数決で決める")
    func majorityWins() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        var batch: [(refKey: String, faces: [DetectedFaceSignal])] = []
        for i in 0..<3 {
            batch.append((refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0], name: "太郎")]))
        }
        // 1 枚だけ外れ値の名前（別人の顔が紛れていた等）。
        batch.append((refKey: "L-a9", faces: [signal([1, 0.02, 0], name: "次郎")]))
        _ = await store.recordScans(batch)

        _ = await store.applySharedNames(batch)
        let after = await store.peopleClusters(minFaces: 1)
        #expect(after.contains { $0.name == "太郎" }, "多数派の名前が採用されていない")
    }
}
