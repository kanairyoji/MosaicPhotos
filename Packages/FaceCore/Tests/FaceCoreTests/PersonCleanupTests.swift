import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 「この人物を整理」（ADR-111）: 混入クラスタのサブグループ化と一括分離。
@Suite("PersonCleanup (この人物を整理)")
struct PersonCleanupTests {

    private func signal(_ vec: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(vec), quality: 0.9)
    }

    /// わずかに揺らした同方向ベクトル（完全一致だと分散 0 で 2-means が縮退するため）。
    private func jittered(_ base: [Float], _ i: Int) -> [Float] {
        var v = base
        v[(i % v.count)] += 0.02 * Float((i % 3) + 1)
        return v
    }

    // MARK: - recursiveSplit（純）

    @Test("3 つの離れた塊は 3 群に再帰分割される")
    func recursiveSplitFindsThreeGroups() {
        var embeddings: [[Float]] = []
        for i in 0..<8 { embeddings.append(jittered([1, 0, 0, 0], i)) }
        for i in 0..<8 { embeddings.append(jittered([0, 1, 0, 0], i)) }
        for i in 0..<8 { embeddings.append(jittered([0, 0, 1, 0], i)) }
        let parts = FaceClusterAudit.recursiveSplit(embeddings: embeddings)
        #expect(parts.count == 3, "3 群に分かれない: \(parts.map(\.count))")
        #expect(parts.allSatisfy { $0.count == 8 })
        // 各群は同じ向きのベクトルだけで構成される（塊が混ざっていない）。
        for part in parts {
            let bands = Set(part.map { $0 / 8 })
            #expect(bands.count == 1, "群に別の塊が混ざった: \(part)")
        }
    }

    @Test("1 つの連続した塊は分割されない")
    func recursiveSplitKeepsSingleBlob() {
        let embeddings = (0..<12).map { jittered([1, 0, 0, 0], $0) }
        let parts = FaceClusterAudit.recursiveSplit(embeddings: embeddings)
        #expect(parts.count == 1)
    }

    /// 実フィードバック: クラスタリングが混ぜた 2 人（類似度 ≈ しきい値 0.4〜0.5）は、
    /// レビュー用の校正値（maxSeparation 0.35）では**構造的に**分割できない。
    /// 整理画面の緩和プロファイル（.cleanup）なら分割候補が出ること。
    @Test("しきい値レベルで混ざった 2 人: レビュー設定では出ないが cleanup 設定では分かれる")
    func cleanupConfigSplitsThresholdLevelMixture() {
        // 群間コサイン ≈ 0.5（クラスタリングが統合し得る近さ）の 2 つの塊。
        var embeddings: [[Float]] = []
        for i in 0..<6 { embeddings.append(jittered([1, 0, 0, 0], i)) }
        for i in 0..<6 { embeddings.append(jittered([0.5, 0.866, 0, 0], i)) }
        let review = FaceClusterAudit.recursiveSplit(
            embeddings: embeddings,
            config: FaceClusterAudit.Config(minMembers: 8, minGroupSize: 3,
                                            minMargin: 0.25, maxSeparation: 0.35))
        #expect(review.count == 1, "前提: レビュー設定では分割されない（これが実障害の機序）")
        let cleanup = FaceClusterAudit.recursiveSplit(embeddings: embeddings, config: .cleanup)
        #expect(cleanup.count == 2, "cleanup 設定で分割候補が出ない: \(cleanup.map(\.count))")
    }

    // MARK: - ストア連携（混入クラスタ → サブグループ → 一括分離）

    /// 2 人ぶんの顔を別クラスタとして育ててから統合（誤統合を再現）→ 整理でサブグループ 2 つ
    /// → 片方を分離 → 2 人物に戻る。
    @Test("混入クラスタをサブグループ化し、一括分離で 2 人に戻せる")
    @MainActor
    func mixedClusterSplitsBack() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<5 { await store.recordScan(refKey: "L-a\(i)", faces: [signal(jittered([1, 0, 0, 0], i))]) }
        for i in 0..<5 { await store.recordScan(refKey: "L-b\(i)", faces: [signal(jittered([0, 1, 0, 0], i))]) }
        var people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 2)
        // 誤統合（まとめて確認で間違えたケース）。
        _ = await store.mergeClusters(from: people[1].clusterID, into: people[0].clusterID)
        people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1, "統合の前提が崩れた")

        let engine = PeopleEngine(faceProvider: nil, store: store)
        let subgroups = await engine.cleanupSubgroups(for: people[0])
        #expect(subgroups.count == 2, "サブグループが 2 つ検出されない: \(subgroups.count)")
        #expect(subgroups.allSatisfy { !$0.isWholeCluster })
        #expect(subgroups.map(\.photoCount) == [5, 5])

        await engine.separateSubgroups([subgroups[1]])
        let after = await store.peopleClusters(minFaces: 3)
        #expect(after.count == 2, "分離後に 2 人へ戻らない: \(after.count)")
    }

    /// 束ねた人物は構成クラスタがそのままサブグループになり、分離＝束ねから外す。
    @Test("束ねグループはクラスタ単位のサブグループになり、分離で束ねから外れる")
    @MainActor
    func groupedPersonSeparatesByCluster() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal(jittered([1, 0, 0, 0], i))]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal(jittered([0, 1, 0, 0], i))]) }
        var people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 2)
        await store.linkClusters(people.map(\.clusterID))
        people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1 && people[0].isGrouped, "束ねの前提が崩れた")

        let engine = PeopleEngine(faceProvider: nil, store: store)
        let subgroups = await engine.cleanupSubgroups(for: people[0])
        #expect(subgroups.count == 2)
        #expect(subgroups.allSatisfy { $0.isWholeCluster }, "束ね内はクラスタ丸ごとのサブグループのはず")

        await engine.separateSubgroups([subgroups[1]])
        let after = await store.peopleClusters(minFaces: 3)
        #expect(after.count == 2, "束ねから外れて 2 人に戻らない: \(after.count)")
        #expect(after.allSatisfy { !$0.isGrouped })
    }
}

/// 大規模クラスタの監査性能（diagnostics-51）: 847 顔クラスタで全ペア類似が
/// 13.9 秒かかりレビューを開くたびメインが飢餓した。統計はサンプルに頭打ちし、
/// **分割の割り当ては全員**に行うことを固定する。
@Suite("FaceClusterAudit sampling (大規模クラスタ)")
struct FaceClusterAuditSamplingTests {

    private func jittered(_ base: [Float], _ i: Int) -> [Float] {
        var v = base
        v[(i % v.count)] += 0.02 * Float((i % 5) + 1)
        return v
    }

    @Test("900 顔の混入クラスタ: 高速に分割でき、割り当ては全員に及ぶ")
    func largeMixedClusterSplitsFastAndFully() {
        var embeddings: [[Float]] = []
        var keys: [String] = []
        for i in 0..<500 { embeddings.append(jittered([1, 0, 0, 0], i)); keys.append("A\(i)") }
        for i in 0..<400 { embeddings.append(jittered([0, 1, 0, 0], i)); keys.append("B\(i)") }
        let start = Date()
        let s = FaceClusterAudit.auditForSplit(embeddings: embeddings, photoKeys: keys)
        let elapsed = Date().timeIntervalSince(start)
        #expect(s != nil, "明確な 2 塊が分割されない")
        guard let s else { return }
        // 割り当てはサンプルでなく**全 900 件**。
        #expect(s.groupA.count + s.groupB.count == 900)
        #expect(min(s.groupA.count, s.groupB.count) >= 395,
                "塊の割り当てが崩れた: \(s.groupA.count)/\(s.groupB.count)")
        // 全ペア（〜40万組）なら数秒級。サンプリング後は十分速いこと（余裕を見て 2 秒）。
        #expect(elapsed < 2.0, "監査が遅すぎる: \(elapsed)s")
    }

    @Test("小さいクラスタ（サンプル上限以下）は従来どおり全件で統計を取る")
    func smallClusterUnchanged() {
        var embeddings: [[Float]] = []
        for i in 0..<8 { embeddings.append(jittered([1, 0, 0, 0], i)) }
        for i in 0..<8 { embeddings.append(jittered([0, 1, 0, 0], i)) }
        let s = FaceClusterAudit.auditForSplit(embeddings: embeddings)
        #expect(s != nil)
        #expect((s?.groupA.count ?? 0) + (s?.groupB.count ?? 0) == 16)
    }
}

// MARK: - 一括レビューの候補生成（取得を 1 回にまとめた回帰）

/// ⚠️ 「次の人へ」で数秒待たされる（実フィードバック）。候補生成がクラスタごとに
/// `faces(inCluster:)` を呼んでおり、人物が 1,316 人まで育ったライブラリでは
/// **1 画面で 1,316 回の fetch** が走っていた。取得を 1 回にまとめたが、
/// **選ばれる候補は一切変わらないこと**を押さえる（しきい値・順序は精度台帳の対象）。
@Suite("一括レビューの候補生成")
struct BatchReviewCandidateTests {

    private func store() -> FaceStore { FaceStore(isStoredInMemoryOnly: true) }

    private func signal(_ vector: [Float], quality: Float = 0.9) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(vector), quality: quality)
    }

    @Test("まとめ取りでもクラスタごとの顔が正しく束ねられる")
    func facesAreGroupedPerCluster() async {
        let store = store()
        // 別人 2 人（直交ベクトル）を、それぞれ 3 枚ずつ。
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }

        let all = await store.allFacesInClustersForTesting()
        var grouped: [Int: Int] = [:]
        for face in all { grouped[face.clusterID ?? -1, default: 0] += 1 }

        #expect(all.count == 6, "1 回の取得で全クラスタの顔が揃わないと候補が欠ける")
        #expect(grouped.values.sorted() == [3, 3], "束ね直しがクラスタごとに正しくない")
        #expect(!grouped.keys.contains(-1), "未割り当ての顔が混ざっている")
    }

    @Test("クラスタ単位の取得と同じ結果になる")
    func matchesPerClusterFetch() async {
        let store = store()
        for i in 0..<4 { await store.recordScan(refKey: "L-x\(i)", faces: [signal([1, 0, 0])]) }
        let counts = await store.clusterCountsForTesting()
        guard let cid = counts.keys.first else { return }

        let viaAll = await store.allFacesInClustersForTesting()
            .filter { $0.clusterID == cid }.map(\.faceID).sorted()
        let viaCluster = await store.facesForTesting(inCluster: cid).sorted()
        #expect(viaAll == viaCluster, "まとめ取りで取りこぼし・混入がある")
    }
}
