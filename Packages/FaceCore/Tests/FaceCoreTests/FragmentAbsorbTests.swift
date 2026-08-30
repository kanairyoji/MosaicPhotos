import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 断片（1〜2 枚）の自動吸収（ADR-154）。
///
/// ⚠️ 人物どうしの結合は自動化しない（ADR-153）。ここが別扱いなのは**失敗の代償が小さい**から
/// ——断片が入っても大きな人物の重心は動かず、間違いは 1 枚外せば直る。
/// だからこそ「紛らわしいものは吸わない」条件を厳しく持つ。
@Suite("断片の自動吸収", .serialized)
struct FragmentAbsorbTests {

    private func signal(_ v: [Float], quality: Float = 0.9) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// 断片を「別クラスタとして割れている」状態にする。
    /// ⚠️ 本番では、合流できなかった経緯（マージンゲート・順序・同一写真）があって断片になる。
    /// テストでその経緯を再現するのは本質ではないので、割れた状態を直接作る。
    private func separate(_ store: FaceStore, refKeyPrefix: String, from personID: Int) async {
        let ids = await store.facesForCluster(clusterID: personID)
            .filter { $0.refKey.hasPrefix(refKeyPrefix) }.map(\.faceID)
        if !ids.isEmpty { _ = await store.splitClusterForTesting(clusterID: personID, faceIDs: ids) }
    }

    /// 確立した人物（12 枚・命名済み）を作る。
    private func makeEstablished(_ store: FaceStore, prefix: String, base: [Float]) async -> Int {
        for i in 0..<12 {
            await store.recordScan(refKey: "\(prefix)\(i)",
                                   faces: [signal([base[0], base[1] + Float(i) * 0.002, base[2]])])
        }
        let map = await store.memberRefKeysByCluster()
        let id = map.first { $0.value.contains("\(prefix)0") }?.key ?? -1
        await store.rename(clusterID: id, name: prefix)
        return id
    }

    @Test("紛らわしくない断片は、確立した人物へ吸収される")
    func absorbsClearFragment() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let personID = await makeEstablished(store, prefix: "L-taro", base: [1, 0, 0])
        // 断片: 本人と cos 0.93（近い）。他に似た人物はいない。
        await store.recordScan(refKey: "L-frag0", faces: [signal([0.93, 0.367, 0])])
        await separate(store, refKeyPrefix: "L-frag", from: personID)
        let before = await store.memberRefKeysByCluster()
        #expect(before[personID]?.count == 12, "fixture: 確立した人物が 12 枚になっていない")
        #expect(before.contains { $0.value.contains("L-frag0") && $0.key != personID },
                "fixture: 断片が別クラスタになっていない")

        let journalBefore = await store.correctionCount()
        let result = await store.absorbFragments()
        #expect(result.absorbed == 1)
        let after = await store.memberRefKeysByCluster()
        #expect(after[personID]?.contains("L-frag0") == true, "断片が吸収されていない")
        // ⚠️ 機械の判断はジャーナルに残さない（ADR-152）。命名で 1 件入るので、その前後で比べる。
        #expect(await store.correctionCount() == journalBefore,
                "自動吸収が修正ジャーナルを汚している")
    }

    @Test("近い人物が 2 人いる断片は吸収しない（人に尋ねる）")
    func skipsAmbiguousFragment() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        _ = await makeEstablished(store, prefix: "L-taro", base: [1, 0, 0])
        // ⚠️ 2 人は**合流しない**距離に置く（cos 0.40）。近すぎると setup の時点で 1 人になり、
        // 「紛らわしい」状況を作れない。
        _ = await makeEstablished(store, prefix: "L-jiro", base: [0.4, 0.917, 0])
        // 断片は 2 人のちょうど中間（どちらにも cos 0.84・差はほぼ 0）。
        await store.recordScan(refKey: "L-frag0", faces: [signal([0.836, 0.548, 0])])
        let map = await store.memberRefKeysByCluster()
        if let owner = map.first(where: { $0.value.contains("L-frag0") && $0.value.count > 1 })?.key {
            await separate(store, refKeyPrefix: "L-frag", from: owner)
        }
        let result = await store.absorbFragments()
        #expect(result.absorbed == 0, "紛らわしい断片を吸収した")
        #expect(result.skipped >= 1)
    }

    @Test("名前やアンカーのある小さな人物は吸収しない")
    func skipsUserStatedFragment() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let taroID = await makeEstablished(store, prefix: "L-taro", base: [1, 0, 0])
        await store.recordScan(refKey: "L-frag0", faces: [signal([0.93, 0.367, 0])])
        await separate(store, refKeyPrefix: "L-frag", from: taroID)
        let map = await store.memberRefKeysByCluster()
        guard let fragID = map.first(where: { $0.value.contains("L-frag0") })?.key else {
            Issue.record("fixture: 断片が無い"); return
        }
        await store.rename(clusterID: fragID, name: "この子")   // ユーザーが名前を付けた

        let result = await store.absorbFragments()
        #expect(result.absorbed == 0, "ユーザーが名前を付けた人物を機械が畳んだ")
    }

    @Test("同じ写真に一緒に写っている断片は吸収しない")
    func skipsSamePhotoFragment() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let personID = await makeEstablished(store, prefix: "L-taro", base: [1, 0, 0])
        // 同じ写真に本人と断片の顔が両方ある（＝同一人物ではあり得ない）。
        await store.recordScan(refKey: "L-both",
                               faces: [signal([1, 0.02, 0]), signal([0.93, 0.367, 0])])
        let result = await store.absorbFragments()
        #expect(result.absorbed == 0, "同一写真の相手を吸収した")
        let after = await store.memberRefKeysByCluster()
        #expect(after[personID]?.contains("L-both") == true, "fixture: 本人側は写真を持っている")
    }
}
