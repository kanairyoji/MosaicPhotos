import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// FaceStore の学習ループ（ADR-46）をインメモリ SwiftData で統合テストする:
/// レビュー生成（A1/A2）→ 回答（統合/確認/分離）→ 制約付き再クラスタ（B2）。
@Suite("FaceStore learning (review + rebuild)", .serialized)
struct FaceStoreLearningTests {

    /// 3 次元の擬似埋め込みで顔信号を作る。
    private func signal(_ v: [Float], quality: Float = 1) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// A 人物（x 方向）と B 人物（y 方向）の顔を投入したストアを作る。
    private func makeStore() async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // A: 4 枚（クラスタ 0 になる）
        for i in 0..<4 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.02, 0])])
        }
        // B: 3 枚（クラスタ 1）
        for i in 0..<3 {
            await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.02])])
        }
        return store
    }

    @Test("境界の顔（A2）がレビューに出て、confirm でアンカー化・以後は出ない")
    func boundaryReviewAndConfirm() async {
        // メンバー数を多めにする（境界顔の追加で重心が引っ張られても、追加後の類似が
        // 境界帯（しきい値+0.10 未満）に残るように）。
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<10 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        // 境界の顔: 重心との事前 cos ≈ 0.47（合流はする）→ 追加後 cos ≈ 0.54 ＝境界帯
        //（10 メンバーの同一埋め込みに対し edge の寄与 1/11 で重心がわずかに動く前提の計算）。
        await store.recordScan(refKey: "L-edge", faces: [signal([1, 1.88, 0])])
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        let confirmItem = items.compactMap { item -> PersonInfo.Face? in
            if case .isThisPerson(let face, _, _, _) = item { return face }
            return nil
        }.first { $0.refKey == "L-edge" }
        #expect(confirmItem != nil)

        // 「はい」＝確認 → アンカーになり、レビューから消える。
        if let face = confirmItem {
            await store.confirmFace(faceID: face.faceID)
            let after = await store.reviewItems(minFaces: 3, limit: 30)
            #expect(!after.contains { item in
                if case .isThisPerson(let f, _, _, _) = item { return f.faceID == face.faceID }
                return false
            })
            #expect(await store.correctionCount() == 1)
        }
    }

    @Test("統合サジェスト（A1）: いいえ（notSame）で以後提案されない")
    func mergeSuggestionAndReject() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 同一人物が 2 クラスタに割れた状況（重心類似 ≈ 0.40 = 0.45 の一歩手前）。
        for i in 0..<3 {
            await store.recordScan(refKey: "L-p\(i)", faces: [signal([1, 0, 0.01 * Float(i)])])
        }
        for i in 0..<3 {
            await store.recordScan(refKey: "L-q\(i)", faces: [signal([0.4, 0.917, 0])])   // cos≈0.40
        }
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        let merge = items.first { if case .samePerson = $0 { return true }; return false }
        #expect(merge != nil)

        if case .samePerson(let a, _, _, let b, _, _, _)? = merge {
            // 「いいえ」＝別人 → 記録され、以後は提案されない。
            await store.markNotSamePerson(clusterA: a, clusterB: b)
            let after = await store.reviewItems(minFaces: 3, limit: 30)
            #expect(!after.contains { if case .samePerson = $0 { return true }; return false })
        }
    }

    @Test("制約付き再クラスタ（B2）: 命名クラスタの ID と名前が保持される")
    func rebuildPreservesNamedClusters() async {
        let store = await makeStore()
        // A クラスタ（clusterID を people から取得）に命名＋確認顔を作る。
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 2)
        let aID = people[0].clusterID
        await store.rename(clusterID: aID, name: "山田太郎")
        if let anchor = await store.facesForCluster(clusterID: aID).first {
            await store.confirmFace(faceID: anchor.faceID)
        }

        let result = await store.rebuildClusters()
        #expect(result.clusters >= 2)

        // 名前と ID が保持され、メンバーも維持される。
        let after = await store.peopleClusters(minFaces: 3)
        let taro = after.first { $0.name == "山田太郎" }
        #expect(taro != nil)
        #expect(taro?.clusterID == aID)
        #expect((taro?.count ?? 0) >= 3)
    }
}
