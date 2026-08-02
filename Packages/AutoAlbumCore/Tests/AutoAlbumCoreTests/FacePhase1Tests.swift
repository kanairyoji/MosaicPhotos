import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import AutoAlbumCore

/// 顔認識フェーズ1（ADR-54）: clusterAll 衛生修正・マルチクロップ平均・
/// 同一写真 cannot-link・共起 notSame・統合サジェスト帯域拡張。
@Suite("FacePhase1 (cannot-link + co-occurrence + multi-crop)", .serialized)
struct FacePhase1Tests {

    private func signal(_ v: [Float], quality: Float = 1) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    // MARK: - ① clusterAll 衛生修正

    @Test("clusterAll は qualityFloor と qualities を尊重する")
    func clusterAllRespectsQuality() {
        let faces: [(faceID: String, embedding: [Float])] = [
            ("good1", [1, 0, 0]), ("good2", [1, 0.02, 0]), ("blurry", [1, 0.01, 0]),
        ]
        // blurry は品質 0.2 < floor 0.4 → クラスタに入らない。
        let clusters = FaceClustering.clusterAll(faces, threshold: 0.5,
                                                 qualityFloor: 0.4,
                                                 qualities: ["blurry": 0.2])
        #expect(clusters.count == 1)
        #expect(clusters[0].count == 2)
        #expect(!clusters[0].faceIDs.contains("blurry"))
    }

    // MARK: - ④ マルチクロップ平均（純関数）

    @Test("averagedEmbedding は要素平均→再正規化・次元不一致は nil")
    func averagedEmbedding() {
        let avg = FaceClustering.averagedEmbedding([[1, 0, 0], [0, 1, 0]])
        #expect(avg != nil)
        // (0.5,0.5,0) を正規化 → (0.707, 0.707, 0)
        #expect(abs(avg![0] - 0.7071) < 1e-3)
        #expect(abs(avg![1] - 0.7071) < 1e-3)
        #expect(abs(FaceClustering.dot(avg!, avg!) - 1) < 1e-4)   // 単位ベクトル
        // 1 本だけなら正規化のみ。
        let single = FaceClustering.averagedEmbedding([[3, 4, 0]])
        #expect(abs(single![0] - 0.6) < 1e-4)
        // 次元不一致・空は nil。
        #expect(FaceClustering.averagedEmbedding([[1, 0], [1, 0, 0]]) == nil)
        #expect(FaceClustering.averagedEmbedding([]) == nil)
    }

    // MARK: - P2 自動プロトタイプ / P3 連鎖統合（ADR-56）

    @Test("selectPrototypes は多様な代表を最遠点順に選び、似た顔は追加しない")
    func selectPrototypesDiversity() {
        let members: [(embedding: [Float], quality: Float)] = [
            ([1, 0, 0], 1.0), ([0.99, 0.05, 0], 0.9),   // ほぼ同じ向き
            ([0, 1, 0], 0.8),                            // 別の見た目（例: 幼児期）
            ([0, 0, 1], 0.3),                            // 品質不足 → 代表にしない
        ]
        let protos = FaceClustering.selectPrototypes(members, limit: 5)
        #expect(protos.count == 2)   // [1,0,0] 系から 1 つ＋[0,1,0]（低品質は除外・重複は追加しない）
        #expect(FaceClustering.selectPrototypes(members, limit: 0).isEmpty)
    }

    @Test("自動プロトタイプ: 重心から遠い成長後の顔もプロトタイプ経由で合流する")
    func autoPrototypeRescues() {
        var clustering = FaceClustering(threshold: 0.6, qualityFloor: 0)
        clustering.autoPrototypeLimit = 5
        clustering.assign(faceID: "baby1", embedding: [1, 0, 0])
        clustering.assign(faceID: "baby2", embedding: [0.98, 0.1, 0])
        // 幼児期と cos≈0.6 の「成長後」の顔: しきい値 0.6 でギリギリ合流し、代表として保持される。
        let grown: [Float] = FaceClustering.normalized([0.6, 0.8, 0])
        let cid = clustering.assign(faceID: "grown1", embedding: grown)
        #expect(cid == clustering.clusters[0].id)
        #expect(clustering.clusters[0].prototypes.count >= 2)   // 初回顔＋成長後の顔
        // さらに成長した顔（幼児期とは cos≈0.28 で重心では届かない）が、代表経由で合流する。
        let cid2 = clustering.assign(faceID: "grown2", embedding: FaceClustering.normalized([0.3, 0.95, 0]))
        #expect(cid2 == clustering.clusters[0].id)
        // 無効（limit 0）なら grown2（重心と cos≈0.35 で届かない）は新規クラスタになる
        //（＝上の合流がプロトタイプ経由だったことの対照）。
        var off = FaceClustering(threshold: 0.6, qualityFloor: 0)
        off.assign(faceID: "baby1", embedding: [1, 0, 0])
        off.assign(faceID: "baby2", embedding: [0.98, 0.1, 0])
        off.assign(faceID: "grown2", embedding: FaceClustering.normalized([0.3, 0.95, 0]))
        #expect(off.clusters.count == 2)
    }

    @Test("chainMergePlan は推移的に統合し、blocked ペアは統合しない")
    func chainMergeTransitive() {
        func cluster(_ id: Int, _ centroid: [Float]) -> FaceClustering.Cluster {
            let v = FaceClustering.normalized(centroid)
            return FaceClustering.Cluster(id: id, centroid: v, sum: v, count: 3, faceIDs: [])
        }
        // A(0°)-B(40°)-C(80°): 隣接は cos≈0.77 で繋がり、A-C は cos≈0.17 でも鎖で同一へ。
        let a = cluster(1, [1, 0, 0])
        let b = cluster(2, [cos(Float.pi * 40 / 180), sin(Float.pi * 40 / 180), 0])
        let c = cluster(3, [cos(Float.pi * 80 / 180), sin(Float.pi * 80 / 180), 0])
        let plan = FaceClustering.chainMergePlan(clusters: [a, b, c], threshold: 0.7)
        #expect(plan[2] == 1)
        #expect(plan[3] == 1)   // 推移的統合（A-C 直接類似は 0.17）
        // blocked（別人記録・共起など）は繋がない。
        let guarded = FaceClustering.chainMergePlan(clusters: [a, b, c], threshold: 0.7) { x, y in
            Set([x, y]) == Set([2, 3])
        }
        #expect(guarded[2] == 1)
        #expect(guarded[3] == nil)   // B-C が blocked → C は孤立
    }

    // MARK: - サイズ適応マージン（ADR-58）

    @Test("sizeMargin: シングルトンで最大・成熟サイズで 0・線形減衰")
    func sizeMarginDecay() {
        var c = FaceClustering(threshold: 0.55)
        c.sizeAdaptiveMarginMax = 0.05
        c.sizeAdaptiveMatureCount = 11
        #expect(abs(c.sizeMargin(forCount: 1) - 0.05) < 1e-6)      // 最大
        #expect(abs(c.sizeMargin(forCount: 11) - 0) < 1e-6)        // 成熟で 0
        #expect(c.sizeMargin(forCount: 20) == 0)                   // 成熟超も 0
        // 中間は単調減少。
        #expect(c.sizeMargin(forCount: 3) < c.sizeMargin(forCount: 2))
        // 無効（max 0）なら常に 0。
        var off = FaceClustering(threshold: 0.55)
        #expect(off.sizeMargin(forCount: 1) == 0)
    }

    @Test("小クラスタは紛らわしい顔を吸い込まず、成熟クラスタは吸収する")
    func sizeAdaptiveRejectsSmallCluster() {
        // 小クラスタ（2 顔）に対し、しきい値ギリギリ（sim≈0.57）の顔を入れる。
        let faces: [(faceID: String, embedding: [Float])] = [
            ("a1", [1, 0, 0]), ("a2", [0.99, 0.05, 0]),
            ("near", FaceClustering.normalized([1, 0.95, 0])),   // 重心と cos≈0.74
        ]
        // sizeMargin なし: near は合流する。
        let base = FaceClustering.clusterAll(faces, threshold: 0.55, qualityFloor: 0)
        #expect(base.count == 1)
        // sizeMargin あり（max 0.25 で誇張）: 2 顔の小クラスタは実効しきい値が上がり合流しない。
        let adaptive = FaceClustering.clusterAll(faces, threshold: 0.55, qualityFloor: 0,
                                                 sizeAdaptiveMarginMax: 0.25)
        #expect(adaptive.count == 2)
    }

    // MARK: - A. 同一写真 cannot-link

    @Test("同一写真の 2 顔は同一埋め込みでも別クラスタになる")
    func samePhotoCannotLink() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 1 枚の写真に「同じ埋め込み」の顔が 2 つ（双子・誤検出想定）。
        await store.recordScan(refKey: "L-twins", faces: [signal([1, 0, 0]), signal([1, 0, 0])])
        // 従来は両方が同じクラスタに入った。cannot-link で 2 クラスタに分かれる。
        let boxes0 = await store.faceBoxes(refKey: "L-twins", clusterID: 0)
        let boxes1 = await store.faceBoxes(refKey: "L-twins", clusterID: 1)
        #expect(boxes0.count == 1)
        #expect(boxes1.count == 1)
    }

    @Test("別写真の同一人物は従来どおり合流する（cannot-link の過剰適用なし）")
    func differentPhotosStillMerge() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])])
        }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1)
        #expect(people.first?.count == 3)
    }

    // MARK: - B. 共起 notSame（統合サジェスト抑制）

    @Test("3 枚以上一緒に写る 2 クラスタは統合サジェストに出ない")
    func coOccurrenceSuppressesMergeSuggestion() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 兄弟想定: 類似度 ≈ 0.40（帯域内）の 2 人が同じ写真に 3 回一緒に写る。
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0.5, 0.866, 0]   // cos ≈ 0.50（帯域 [0.45,1.0] 内・合流 0.55 未満）
        for i in 0..<3 {
            await store.recordScan(refKey: "L-both\(i)", faces: [signal(a), signal(b)])
        }
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        #expect(!items.contains { if case .samePerson = $0 { return true }; return false })
    }

    @Test("共起なしの帯域内ペアは従来どおりサジェストされる")
    func nonCoOccurringPairStillSuggested() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await store.recordScan(refKey: "L-p\(i)", faces: [signal([1, 0, 0.01 * Float(i)])])
        }
        for i in 0..<3 {
            await store.recordScan(refKey: "L-q\(i)", faces: [signal([0.5, 0.866, 0])])
        }
        let items = await store.reviewItems(minFaces: 3, limit: 30)
        #expect(items.contains { if case .samePerson = $0 { return true }; return false })
    }
}
