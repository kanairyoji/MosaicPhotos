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
