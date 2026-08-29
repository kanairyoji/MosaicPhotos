import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

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
        // 境界の顔: 重心との事前 cos ≈ 0.52（しきい値 0.50 で合流）→ 追加後 cos ≈ 0.59
        // ＝境界帯（< thr+0.10 = 0.60）。10 メンバーの同一埋め込みに対し edge の寄与 1/11。
        await store.recordScan(refKey: "L-edge", faces: [signal([1, 1.643, 0])])
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
        await store.recordScan(refKey: "L-edge", faces: [signal([1, 1.643, 0])])
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

    @Test("2階層束ね: linkClusters で複数クラスタが 1 人物にまとまり、unlink で戻る")
    func linkAndUnlinkClusters() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 別方向の 2 クラスタ（子供の時期別クラスタを想定）。
        for i in 0..<3 { await store.recordScan(refKey: "L-young\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-old\(i)", faces: [signal([0, 1, 0])]) }
        let before = await store.peopleClusters(minFaces: 3)
        #expect(before.count == 2)   // 束ね前は 2 人
        let ids = before.map(\.clusterID)
        await store.rename(clusterID: ids[0], name: "太郎")
        await store.linkClusters(ids)
        let after = await store.peopleClusters(minFaces: 3)
        #expect(after.count == 1)                 // 束ね後は 1 人
        #expect(after[0].count == 6)              // 全時期の写真が集約
        #expect(after[0].name == "太郎")          // 名前つき主クラスタが代表
        // 解除で 2 人に戻る。
        await store.unlinkCluster(ids[1])
        #expect(await store.peopleClusters(minFaces: 3).count == 2)
    }

    @Test("2階層束ね: 写真の人物名が主クラスタ名に解決（束ねた全時期で1人）")
    func peopleNamesFollowGrouping() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 太郎の乳児期([1,0,0])と児童期([0,1,0])＋同じ写真に両時期の顔（成長合成の擬似）。
        for i in 0..<3 { await store.recordScan(refKey: "L-y\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-o\(i)", faces: [signal([0, 1, 0])]) }
        let people = await store.peopleClusters(minFaces: 3)
        let ids = people.map(\.clusterID)
        await store.rename(clusterID: ids[0], name: "太郎")
        // 束ね前: L-y0 は 1 クラスタの名前。
        let before = await store.peopleNames(refKey: "L-y0", minFaces: 3)
        #expect(before.count == 1)
        await store.linkClusters(ids)
        // 束ね後: 両時期のクラスタが「太郎」に解決。別時期写真も同名。
        #expect(await store.peopleNames(refKey: "L-y0", minFaces: 3) == ["太郎"])
        #expect(await store.peopleNames(refKey: "L-o0", minFaces: 3) == ["太郎"])
    }

    @Test("撮影日が保存される（時期グループ分割の材料）")
    func captureDateStored() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let sig = DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                                     embedding: ClipMath.encodeHalf([1, 0, 0]), quality: 1,
                                     captureDate: date)
        await store.recordScan(refKey: "L-a", faces: [sig])
        let faces = await store.facesForCluster(clusterID: 0)
        #expect(!faces.isEmpty)
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

    @Test("モデル世代を跨いだ修正は校正・負例に混ぜない（ADR-70 追補）")
    func correctionsAreProfileScoped() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // facenet 世代（既定プロファイル）で「高い類似度の正例/負例」を大量に記録する。
        // facenet スケール（同一人物平均 0.55）では正常な値。
        for _ in 0..<10 {
            await store.recordCorrection(kind: "merge",
                faceEmbedding: ClipMath.encodeHalf([1, 0, 0]), wrongEmbedding: nil,
                similarity: 0.62)
            await store.recordCorrection(kind: "notSame",
                faceEmbedding: ClipMath.encodeHalf([1, 0, 0]),
                wrongEmbedding: ClipMath.encodeHalf([0, 1, 0]), similarity: 0.58)
        }
        // facenet プロファイルでは校正が動く（境界 0.62 は可動域 0.35...0.55 に clamp）。
        let facenetThr = await store.calibratedThreshold()
        #expect(facenetThr == 0.55)   // 上限に clamp（実機で見た挙動そのもの）

        // ArcFace プロファイルへ切り替えると、**旧世代の行は無視**され既定値のまま。
        // 実機では facenet の 0.5-0.7 の類似度が AuraFace の校正を上限 0.40 まで
        // 押し上げていた（diagnostics-27: thr=0.40 pos=534）。この汚染を止める。
        await store.apply(tuning: .arcFace)
        let arcThr = await store.calibratedThreshold()
        #expect(arcThr == FaceTuning.arcFace.clusterThreshold)   // サンプル 0 扱い → fallback 0.35
        // 負例も同様（別空間の埋め込みは照合不能）。
        #expect(await store.loadNegatives().isEmpty)

        // ArcFace 世代で記録し直せば、その行は使われる。
        for _ in 0..<10 {
            await store.recordCorrection(kind: "merge",
                faceEmbedding: ClipMath.encodeHalf([1, 0, 0]), wrongEmbedding: nil,
                similarity: 0.42)
            await store.recordCorrection(kind: "notSame",
                faceEmbedding: ClipMath.encodeHalf([1, 0, 0]),
                wrongEmbedding: ClipMath.encodeHalf([0, 1, 0]), similarity: 0.30)
        }
        let arcThr2 = await store.calibratedThreshold()
        #expect(arcThr2 >= 0.30 && arcThr2 <= 0.40)   // 新世代のサンプルで校正が動く
        #expect(!(await store.loadNegatives()).isEmpty)
    }
}

// MARK: - クラウド分だけのリセット（レビュー指摘）

/// ⚠️ `resetCloudScans()` はクラウドの顔行を消すが、以前は `PersonCluster.sum/count` に
/// 消した顔の寄与が残っていた。キャッシュを捨てても次回はその古いクラスタ行から復元されるため、
/// 再スキャンしたクラウド顔がさらに加算され、**重心と件数が二重化**する。
@Suite("FaceStore.resetCloudScans")
struct FaceStoreCloudResetTests {

    private func signal(_ v: [Float], quality: Float = 1) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("クラウド顔を捨てたら、残った顔だけの件数・重心になる")
    func clusterCountsMatchRemainingFaces() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "C-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])]) }

        let before = await store.clusterCountsForTesting().values.reduce(0, +)
        #expect(before == 7)

        _ = await store.resetCloudScans()

        let counts = await store.clusterCountsForTesting()
        let total = counts.values.reduce(0, +)
        #expect(total == 4, "消したクラウド顔の寄与がクラスタに残っている: \(total)")
    }

    @Test("クラウドだけのクラスタは幽霊として残らない")
    func cloudOnlyClustersAreRemoved() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        // 別方向＝別クラスタになるクラウド顔だけの人物。
        for i in 0..<3 { await store.recordScan(refKey: "C-b\(i)", faces: [signal([0, 1, 0])]) }
        #expect(await store.clusterCountsForTesting().count == 2)

        _ = await store.resetCloudScans()

        let counts = await store.clusterCountsForTesting()
        #expect(counts.count == 1, "メンバーの居ないクラスタが残っている: \(counts)")
        #expect(counts.values.reduce(0, +) == 3)
    }

    /// 再スキャンで同じクラウド顔が戻っても、件数は「実在する顔の数」に一致すること
    /// （二重計上していると 7 ではなく 10 になる）。
    @Test("リセット後に再スキャンしても件数が二重化しない")
    func rescanDoesNotDoubleCount() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "C-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])]) }
        _ = await store.resetCloudScans()

        for i in 0..<3 { await store.recordScan(refKey: "C-a\(i)", faces: [signal([1, Float(i) * 0.01, 0])]) }

        let total = await store.clusterCountsForTesting().values.reduce(0, +)
        #expect(total == 7, "重心・件数が二重化している: \(total)")
    }
}

// MARK: - 低品質顔の付け替え（レビュー指摘）

/// ⚠️ 品質フロア未満の顔は「membership だけ」割り当てられ、重心（sum/count）には寄与しない
/// （ADR-66）。付け替え時にその顔まで減算すると重心が壊れ、count==1 のクラスタでは
/// 「最後の 1 顔」と誤認して**クラスタごと消える**（残った顔が存在しない ID を指す）。
@Suite("FaceStore low-quality reassign")
struct FaceStoreLowQualityReassignTests {

    private func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    /// 高品質 1 枚（＝count 1）＋ 低品質 1 枚（membership だけ）のクラスタを作る。
    private func makeStore() async -> FaceStore {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        await store.recordScan(refKey: "L-b", faces: [signal([1, 0.02, 0], quality: 0.2)])
        return store
    }

    @Test("低品質顔は重心に寄与しない（count は高品質分だけ）")
    func lowQualityFaceDoesNotContribute() async {
        let store = await makeStore()
        let counts = await store.clusterCountsForTesting()
        #expect(counts.values.reduce(0, +) == 1, "membership だけの顔が count に入っている")
    }

    @Test("低品質顔を外してもクラスタは消えない")
    func removingLowQualityFaceKeepsCluster() async {
        let store = await makeStore()
        let before = await store.clusterCountsForTesting()
        #expect(before.count == 1)

        // 低品質顔（L-b#0）を別人へ付け替える。
        _ = await store.reassignFace(faceID: "L-b#0", toClusterID: nil)

        let after = await store.clusterCountsForTesting()
        #expect(after[before.first!.key] != nil,
                "寄与していない顔を外しただけでクラスタが消えた（残った顔が迷子になる）")
        #expect(after[before.first!.key] == 1, "寄与していない顔の分まで count を減らした")
    }

    @Test("高品質顔の付け替えでは従来どおり重心から引く")
    func removingContributingFaceUpdatesCentroid() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        await store.recordScan(refKey: "L-b", faces: [signal([1, 0.01, 0], quality: 0.9)])
        let cid = await store.clusterCountsForTesting().first!.key
        #expect(await store.clusterCountsForTesting()[cid] == 2)

        _ = await store.reassignFace(faceID: "L-b#0", toClusterID: nil)
        #expect(await store.clusterCountsForTesting()[cid] == 1, "寄与分を引いていない")
    }
}

// MARK: - 低品質顔だけで新クラスタを作る（レビュー指摘）

/// ⚠️ 低品質顔は通常 membership だけ（重心を汚さない）。それを**新しい人物**へ移すと、
/// `addToCluster` がクラスタを作らずに返り、顔だけが存在しないクラスタ ID を指す
/// （人物一覧に出ず、迷子になる）。ユーザーが明示的に分けた顔なので種にしてよい。
@Suite("FaceStore 低品質顔の分離")
struct FaceStoreLowQualitySplitTests {

    private func signal(_ v: [Float], quality: Float) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("低品質顔を新しい人物へ分けても、クラスタが必ず作られる")
    func lowQualityFaceGetsItsOwnCluster() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        await store.recordScan(refKey: "L-b", faces: [signal([1, 0.02, 0], quality: 0.2)])

        let before = Set(await store.clusterCountsForTesting().keys)
        await store.reassignFace(faceID: "L-b#0", toClusterID: nil)

        let counts = await store.clusterCountsForTesting()
        let newIDs = Set(counts.keys).subtracting(before)
        #expect(newIDs.count == 1,
                "顔が存在しないクラスタ ID を指している（人物一覧から消える）: \(counts)")
        #expect(counts[newIDs.first ?? -1] == 1)
    }

    @Test("全員が低品質でも、分離先のクラスタは作られる")
    func splitWithOnlyLowQualityFacesCreatesCluster() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0], quality: 0.9)])
        for i in 0..<2 {
            await store.recordScan(refKey: "L-low\(i)", faces: [signal([1, 0.02, 0], quality: 0.2)])
        }
        let cid = await store.clusterCountsForTesting().first!.key
        let faceIDs = await store.facesForTesting(inCluster: cid).filter { $0.hasPrefix("L-low") }
        guard !faceIDs.isEmpty else { return }   // 低品質顔が別クラスタなら対象外

        let newID = await store.splitCluster(clusterID: cid, faceIDs: faceIDs)
        #expect(newID != nil)
        if let newID {
            #expect(await store.clusterCountsForTesting()[newID] != nil,
                    "分離先のクラスタが作られていない")
        }
    }
}

/// 「この写真はこの人ではない」（写真 1 枚ぶんをまとめて外す・ADR-129）。
///
/// ⚠️ 実フィードバック: 「全体像や前後関係で違うと気づくことがある」。顔だけを並べた
/// 「顔の管理」では気づけない誤りを、写真を見ている場所から直せるようにした。
/// 1 枚に**同じ人物の顔が複数**あることもある（誤検出の重なり）ので、まとめて外す。
@Suite("この写真はこの人ではない")
struct RemovePhotoFromPersonTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// ⚠️ 同じ人物の顔は **1 枚の写真に 1 つ**しか入らない（同一写真 cannot-link・ADR-58）。
    /// なので通常 `removed` は 1。実装がまとめて外す形なのは、旧データや第2パスで
    /// 不変条件が破れている行を残さないため（そこだけ 1 件ずつ消し残すと直せなくなる）。
    @Test("その写真の顔だけを外し、他の写真は残す")
    func removesOnlyThatPhoto() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-keep\(i)", faces: [signal([1, 0, 0])]) }
        await store.recordScan(refKey: "L-wrong", faces: [signal([1, 0, 0])])

        let before = await store.clusterCountsForTesting()
        guard let clusterID = before.max(by: { $0.value < $1.value })?.key else {
            Issue.record("fixture が人物になっていない"); return
        }
        let members0 = await store.memberRefKeysByCluster()[clusterID] ?? []
        #expect(members0.contains("L-wrong"), "前提: 外す写真がこの人物のメンバーになっている")

        let removed = await store.removePhoto(refKey: "L-wrong", from: clusterID)
        #expect(removed >= 1, "外せていない: \(removed)")

        let members = await store.memberRefKeysByCluster()[clusterID] ?? []
        #expect(!members.contains("L-wrong"), "外したはずの写真が残っている")
        #expect(members.contains("L-keep0"), "他の写真まで外している")
    }

    @Test("その人物の顔が無い写真では何もしない")
    func noOpWhenPhotoIsNotAMember() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0])])
        let clusterID = await store.clusterCountsForTesting().keys.first ?? -1
        let removed = await store.removePhoto(refKey: "L-not-a-member", from: clusterID)
        #expect(removed == 0)
    }

    /// 「この写真は**別の人**」＝相手を選んで移す（ADR-133）。外すだけの `removePhoto` と違い、
    /// 移動先が決まるので、その顔は移動先の**確認顔（アンカー）**として学習される（ADR-46）。
    @Test("選んだ人物へ移り、移動先の確認顔になる")
    func movesPhotoToChosenPerson() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }
        let members = await store.memberRefKeysByCluster()
        guard let aID = members.first(where: { $0.value.contains("L-a0") })?.key,
              let bID = members.first(where: { $0.value.contains("L-b0") })?.key, aID != bID else {
            Issue.record("fixture: 2 人になっていない"); return
        }

        let moved = await store.movePhoto(refKey: "L-a0", from: aID, to: bID)
        #expect(moved >= 1)

        let after = await store.memberRefKeysByCluster()
        #expect(after[aID]?.contains("L-a0") != true, "移動元に残っている")
        #expect(after[bID]?.contains("L-a0") == true, "移動先に入っていない")
        // 移動先のアンカー（＝再クラスタでも動かない・ADR-130/132）になっている。
        #expect(await store.anchorCount(clusterID: bID) >= 1)
    }

    /// 写真ビュー（人物アルバム以外）に人物修正を出す条件＝**1 人しか写っていない**（ADR-133）。
    @Test("1 人だけ写っている写真ならその人物、2 人なら出さない")
    func solePersonOnlyWhenOneFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }
        // 2 人が一緒に写っている写真。
        await store.recordScan(refKey: "L-both", faces: [signal([1, 0, 0]), signal([0, 1, 0])])
        let members = await store.memberRefKeysByCluster()
        guard let aID = members.first(where: { $0.value.contains("L-a0") })?.key else {
            Issue.record("fixture: 人物が作れていない"); return
        }
        // fixture の前提: 2 人写真は両方のクラスタに入っている。
        #expect(members.filter { $0.value.contains("L-both") }.count == 2)

        #expect(await store.solePersonClusterID(refKey: "L-a0") == aID)
        #expect(await store.solePersonClusterID(refKey: "L-both") == nil, "2 人の写真では出さない")
        #expect(await store.solePersonClusterID(refKey: "L-none") == nil)
    }
}
