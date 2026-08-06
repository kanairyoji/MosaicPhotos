import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

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

    // MARK: - 競合を見るマージン（ADR-68）

    @Test("競合を見るマージン: 競合が同一人物らしければ免除し、別人らしければ従来どおり弾く")
    func rivalAwareMarginGate() {
        // 同一人物の別時期を模した 2 クラスタ（互いに cos≈0.87）。逐次割当だとこの 2 つは
        // 合流してしまうので、**すでに分かれている状態**を種クラスタで直接作る
        //（実ライブラリでは cannot-link や割当順で普通に起きる状態）。
        func seed(_ id: Int, _ v: [Float]) -> FaceClustering.Cluster {
            let n = FaceClustering.normalized(v)
            return .init(id: id, centroid: n, sum: n, count: 5, faceIDs: [])
        }
        func makeClustering(rivalAware: Bool, seeds: [FaceClustering.Cluster]) -> FaceClustering {
            var c = FaceClustering(threshold: 0.5, qualityFloor: 0, seedClusters: seeds)
            c.assignMargin = 0.05
            c.rivalAwareMargin = rivalAware
            return c
        }
        let alike = [seed(1, [1, 0, 0]), seed(2, [0.87, 0.5, 0])]   // 互いに cos≈0.87
        let between = FaceClustering.normalized([0.98, 0.2, 0])     // 1位と2位の差 0.03 < margin

        var off = makeClustering(rivalAware: false, seeds: alike)
        let offID = off.assign(faceID: "mid", embedding: between)
        // 従来: どちらにも入れず新クラスタ（＝分裂の発生源）。
        #expect(off.clusters.count == 3)
        #expect(offID != 1 && offID != 2)

        var on = makeClustering(rivalAware: true, seeds: alike)
        let onID = on.assign(faceID: "mid", embedding: between)
        // 免除: 競合どうしが似ている（同一人物）ので、素直に 1 位へ合流する。
        #expect(on.clusters.count == 2)
        #expect(onID == 1)

        // 対照: 競合が**別人らしい**（互いに似ていない）ときは免除しない。
        let distinctSeeds = [seed(1, [1, 0, 0]), seed(2, [0, 1, 0])]   // cos=0 ＝別人
        var distinct = makeClustering(rivalAware: true, seeds: distinctSeeds)
        let mid2 = FaceClustering.normalized([1, 1, 0])   // 両方に cos≈0.707・差 0 ＝紛らわしい
        let distinctID = distinct.assign(faceID: "mid", embedding: mid2)
        #expect(distinct.clusters.count == 3)             // 従来どおり弾く（兄弟の取り違え防止）
        #expect(distinctID != 1 && distinctID != 2)
    }

    @Test("サイズ免除は少人数ライブラリ限定（人数が増えたら従来どおり弾く）")
    func sizeMarginExemptionOnlyForSmallLibraries() {
        // 16 次元の one-hot で「互いに無関係な人物」を作れるようにする。
        func onehot(_ i: Int, dim: Int = 16) -> [Float] {
            var v = [Float](repeating: 0, count: dim); v[i] = 1; return v
        }
        /// 成熟クラスタ（count=11）を n 個＋小クラスタ 1 個（count=2・方向は onehot(0)）。
        func seeds(maturePeople n: Int) -> [FaceClustering.Cluster] {
            var out: [FaceClustering.Cluster] = [
                .init(id: 0, centroid: onehot(0), sum: onehot(0), count: 2, faceIDs: []),
            ]
            for i in 1...n {
                out.append(.init(id: i, centroid: onehot(i), sum: onehot(i), count: 11, faceIDs: []))
            }
            return out
        }
        // 小クラスタと cos≈0.6（しきい値 0.5 は超えるが、count=2 の上乗せ 0.25 には届かない顔）。
        var v = [Float](repeating: 0, count: 16)
        v[0] = 0.6; v[15] = 0.8
        let borderline = FaceClustering.normalized(v)

        func assign(maturePeople: Int, maxPeople: Int) -> Int {
            var c = FaceClustering(threshold: 0.5, qualityFloor: 0,
                                   seedClusters: seeds(maturePeople: maturePeople))
            c.sizeAdaptiveMarginMax = 0.25
            c.rivalAwareSizeMargin = true
            c.rivalAwareSizeMarginMaxPeople = maxPeople
            return c.assign(faceID: "x", embedding: borderline)
        }
        // 人物が 3 人（少人数）→ 免除が効き、小クラスタが育つ。
        #expect(assign(maturePeople: 3, maxPeople: 10) == 0)
        // 人物が 12 人（上限 10 以上）→ 免除しない＝従来どおり新クラスタ。
        #expect(assign(maturePeople: 12, maxPeople: 10) != 0)
        // 上限 0（無制限）なら人数に関係なく免除する（＝計測用の構成）。
        #expect(assign(maturePeople: 12, maxPeople: 0) == 0)
    }

    @Test("実効しきい値の頭打ち: 少人数では加算せず、大人数では従来どおり加算する")
    func effectiveThresholdCapIsPeopleGated() {
        func onehot(_ i: Int, dim: Int = 16) -> [Float] {
            var v = [Float](repeating: 0, count: dim); v[i] = 1; return v
        }
        /// 小クラスタ（count=2・onehot(0)）＋成熟クラスタ n 個（互いに無関係）。
        func seeds(maturePeople n: Int) -> [FaceClustering.Cluster] {
            var out: [FaceClustering.Cluster] = [
                .init(id: 0, centroid: onehot(0), sum: onehot(0), count: 2, faceIDs: []),
            ]
            for i in 1...n {
                out.append(.init(id: i, centroid: onehot(i), sum: onehot(i), count: 11, faceIDs: []))
            }
            return out
        }
        // 小クラスタと cos≈0.6: 素のしきい値 0.55 は超えるが、サイズ加算後（+0.10 相当）には届かない。
        var v = [Float](repeating: 0, count: 16)
        v[0] = 0.6; v[15] = 0.8
        let borderline = FaceClustering.normalized(v)   // onehot(0) と cos = 0.6

        func assign(maturePeople: Int, cap: Float) -> Int {
            var c = FaceClustering(threshold: 0.55, qualityFloor: 0,
                                   seedClusters: seeds(maturePeople: maturePeople))
            c.sizeAdaptiveMarginMax = 0.10
            c.effectiveThresholdCap = cap
            c.effectiveThresholdCapMaxPeople = 10
            return c.assign(faceID: "x", embedding: borderline)
        }
        // 上限なし: 実効 0.55+0.10=0.65 に届かず新クラスタ（＝実機で起きていた分裂）。
        #expect(assign(maturePeople: 3, cap: 0) != 0)
        // 上限 0.55（＝加算しない）＋少人数: 素のしきい値で判定され合流する。
        #expect(assign(maturePeople: 3, cap: 0.55) == 0)
        // 大人数（成熟 12 人 ≥ 上限 10）: 上限は効かず従来どおり加算＝合流しない。
        #expect(assign(maturePeople: 12, cap: 0.55) != 0)
    }

    @Test("校正しきい値は 0.55 を超えない（分裂側へ振り切らせない）")
    func calibrationIsClampedTo055() {
        // 「高いしきい値が正しい」と示すサンプル（正例も負例も高類似）。
        let positive = [Float](repeating: 0.72, count: 10)
        let negative = [Float](repeating: 0.68, count: 10)
        let t = FaceCalibration.calibratedThreshold(positive: positive, negative: negative)
        #expect(t <= 0.55)
        #expect(FaceCalibration.clampRange.upperBound == 0.55)
    }

    @Test("統合候補の下限は 0.35 まで下がる（成長で離れた同一人物を候補に出す）")
    func mergeBandFloorReachesGrowthGap() {
        // 台帳（face-accuracy.md）: 同一人物でも年齢差 11-20 年は平均 0.440、21 年+ は 0.400。
        // しきい値 0.55 のとき従来の下限は 0.45 で、これらは候補にすら出なかった。
        #expect(FaceStore.mergeBandFloor(threshold: 0.55) == 0.35)
        #expect(FaceStore.mergeBandFloor(threshold: 0.50) == 0.35)
        // しきい値が下限側に寄っているときは従来どおり追従する（帯域が逆転しない）。
        #expect(FaceStore.mergeBandFloor(threshold: 0.40) < 0.35)
        // 別人（両者 12 歳以下＝兄弟の代理）の平均 0.294 は下回らない。
        #expect(FaceStore.mergeBandFloor(threshold: 0.55) > 0.294)
    }

    @Test("検出統計: 理由別に数え、通過とフロア未満を区別する")
    func detectionStatsTally() {
        FaceDetectionStats.reset()
        FaceDetectionStats.record(reason: nil)                            // 通過
        FaceDetectionStats.record(reason: nil, belowQualityFloor: true)   // 通過だがフロア未満
        FaceDetectionStats.record(reason: "low-confidence")
        FaceDetectionStats.record(reason: "low-confidence")
        FaceDetectionStats.record(reason: "size-pixels")
        let s = FaceDetectionStats.snapshot()
        #expect(s.candidates == 5)
        #expect(s.accepted == 2)
        #expect(s.belowQualityFloor == 1)
        #expect(s.rejectedByReason["low-confidence"] == 2)
        #expect(s.rejectedByReason["size-pixels"] == 1)
        #expect(s.logLine.contains("low-confidence=2"))
        FaceDetectionStats.reset()
        #expect(FaceDetectionStats.snapshot().candidates == 0)
    }

    @Test("レビュー母数は UI の人物と一致する（第2パスの顔しかないクラスタも候補になる）")
    func reviewUsesSameEligibilityAsUI() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 実機の典型: **高品質の顔は 1 枚だけ**で、残りは品質フロア未満（横顔・ぶれ・小さい）。
        // 後者は第2パス（ADR-66）で membership だけ付くので `PersonCluster.count` は伸びないが、
        // 写真としては 3 枚あるので UI には人物として出る。実機では全顔の約 48% がこの状態。
        await store.recordScan(refKey: "L-a0", faces: [signal([1, 0, 0], quality: 0.9)])
        for i in 1..<3 {
            await store.recordScan(refKey: "L-a\(i)",
                                   faces: [signal(FaceClustering.normalized([0.99, 0.1, 0]),
                                                  quality: 0.2)])
        }
        let people = await store.peopleClusters(minFaces: 3)
        #expect(people.count == 1)                    // UI では 1 人
        #expect(people.first?.count == 3)             // 写真は 3 枚

        let eligible = await store.peopleEligibleClusters(minFaces: 3)
        #expect(eligible.count == people.count)       // レビュー母数も 1 人（旧実装は 0 だった）
        // 旧実装の判定（重心寄与カウント）では母数から漏れることを明示しておく。
        #expect(eligible.first!.count < 3)
    }

    @Test("品質レポート: 顔が見つからなかった写真を数える")
    func qualityReportCountsPhotosWithNoFace() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.recordScan(refKey: "L-face", faces: [signal([1, 0, 0])])
        await store.recordScan(refKey: "L-empty1", faces: [])
        await store.recordScan(refKey: "L-empty2", faces: [])
        let report = await store.qualityReport(minFaces: 1)
        #expect(report.scannedPhotos == 3)
        #expect(report.photosWithNoFace == 2)
    }

    @Test("品質レポート: 統合で同一写真違反が生まれたら検出する")
    func qualityReportDetectsSamePhotoViolation() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 1 枚に同じ埋め込みの顔が 2 つ → cannot-link で別クラスタになる（違反なし）。
        await store.recordScan(refKey: "L-a", faces: [signal([1, 0, 0]), signal([1, 0, 0])])
        // 各クラスタを 3 顔以上にして「人物」に載せる（別写真なので合流しない）。
        await store.recordScan(refKey: "L-b", faces: [signal([1, 0, 0])])
        await store.recordScan(refKey: "L-c", faces: [signal([1, 0, 0])])
        let before = await store.qualityReport(minFaces: 1)
        #expect(before.samePhotoViolations == 0)

        // ユーザーがこの 2 クラスタを統合すると、1 枚の写真に同じ人物が 2 回になる。
        // 割り当て時の cannot-link は統合を検査しないので、事後に検出できることが重要。
        await store.mergeClusters(from: 1, into: 0)
        let after = await store.qualityReport(minFaces: 1)
        #expect(after.samePhotoViolations == 1)
        #expect(after.samePhotoViolationPhotos == 1)
    }

    @Test("曖昧な顔の扱い: leaveUnassigned はクラスタを増やさない")
    func ambiguousPolicyLeavesUnassigned() {
        var c = FaceClustering(threshold: 0.5, qualityFloor: 0)
        c.assignMargin = 0.05
        c.ambiguousPolicy = .leaveUnassigned
        c.assign(faceID: "x", embedding: FaceClustering.normalized([1, 0, 0]))
        c.assign(faceID: "y", embedding: FaceClustering.normalized([0, 1, 0]))
        let id = c.assign(faceID: "mid", embedding: FaceClustering.normalized([1, 1, 0]))
        #expect(id == FaceClustering.unassigned)
        #expect(c.clusters.count == 2)   // 新クラスタを作らない
    }
}
