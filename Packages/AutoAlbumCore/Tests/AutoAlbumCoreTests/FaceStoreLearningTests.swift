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
        // 境界の顔: 重心との事前 cos ≈ 0.57（しきい値 0.55 で合流）→ 追加後 cos ≈ 0.63
        // ＝境界帯（< thr+0.10 = 0.65）。10 メンバーの同一埋め込みに対し edge の寄与 1/11。
        await store.recordScan(refKey: "L-edge", faces: [signal([1, 1.45, 0])])
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        let confirmItem = items.compactMap { item -> PersonInfo.Face? in
            if case .isThisPerson(let face, _, _, _, _) = item { return face }
            return nil
        }.first { $0.refKey == "L-edge" }
        #expect(confirmItem != nil)

        // 「はい」＝確認 → アンカーになり、レビューから消える。
        if let face = confirmItem {
            await store.confirmFace(faceID: face.faceID)
            let after = await store.reviewItems(minFaces: 3, limit: 30)
            #expect(!after.contains { item in
                if case .isThisPerson(let f, _, _, _, _) = item { return f.faceID == face.faceID }
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
            await store.recordScan(refKey: "L-q\(i)", faces: [signal([0.5, 0.866, 0])])   // cos≈0.50＝帯域[0.45,1.0]内・合流(0.55)未満
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

    @Test("excluding: 出題済みカードは除外され、次点候補で埋まる")
    func excludingSuppressesShownCards() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<10 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        await store.recordScan(refKey: "L-edge", faces: [signal([1, 1.45, 0])])
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        guard let first = items.first else {
            Issue.record("レビューが生成されない")
            return
        }
        // 出題済みとして除外 → 同じカードは返らない。
        let after = await store.reviewItems(minFaces: 3, limit: 30, excluding: [first.id])
        #expect(!after.contains { $0.id == first.id })
    }

    @Test("faceBoxes: 同一写真に同一クラスタの顔が複数でも最良の1顔のみ")
    func faceBoxesReturnsBestSingleFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // クラスタの核（x 方向）を作る。
        for i in 0..<5 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        // 1 枚の写真に 2 顔: 重心に近い顔（本人）と遠い顔（混入）が同一クラスタに入る状況。
        let near = DetectedFaceSignal(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                                      embedding: ClipMath.encodeHalf([1, 0.05, 0]), quality: 1)
        let far = DetectedFaceSignal(boundingBox: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2),
                                     embedding: ClipMath.encodeHalf([1, 0.9, 0]), quality: 1)
        await store.recordScan(refKey: "L-multi", faces: [near, far])
        let people = await store.peopleClusters(minFaces: 3)
        guard let cid = people.first?.clusterID else {
            Issue.record("クラスタが作られない")
            return
        }
        let boxes = await store.faceBoxes(refKey: "L-multi", clusterID: cid)
        // 両顔が同一クラスタに入った場合でも、返るのは重心に近い near の 1 枠のみ。
        #expect(boxes.count <= 1)
        if let box = boxes.first {
            #expect(abs(box.origin.x - 0.1) < 1e-6)
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
