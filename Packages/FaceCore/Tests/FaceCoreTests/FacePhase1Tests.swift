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
        // ⚠️ 尋ねる下限は**しきい値以上**になった（ADR-150）。cos 0.50 は facenet の
        // しきい値ちょうど＝「自動では合流しない（サイズ上乗せがある）が尋ねる価値はある」位置。
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

    @Test("校正しきい値はプロファイルの上限を超えない（分裂側へ振り切らせない）")
    func calibrationIsClampedByProfile() {
        // 「高いしきい値が正しい」と示すサンプル（正例も負例も高類似）。
        let positive = [Float](repeating: 0.72, count: 10).map { ($0, 1.0) }
        let negative = [Float](repeating: 0.68, count: 10).map { ($0, 1.0) }
        let f = FaceCalibration.calibratedThreshold(
            positive: positive, negative: negative,
            fallback: FaceTuning.facenet.clusterThreshold,
            clamp: FaceTuning.facenet.calibrationRange)
        #expect(f <= FaceTuning.facenet.calibrationRange.upperBound)
        let a = FaceCalibration.calibratedThreshold(
            positive: positive, negative: negative,
            fallback: FaceTuning.arcFace.clusterThreshold,
            clamp: FaceTuning.arcFace.calibrationRange)
        #expect(a <= 0.40)   // ArcFace スケールの上限
        #expect(FaceTuning.facenet.calibrationRange.upperBound == 0.55)
    }

    @Test("尋ねる下限はしきい値を下回らない（当たらない対を出さない）")
    func mergeBandFloorStaysAboveThreshold() {
        // ⚠️ 以前は「成長で離れた同一人物を拾う」ために**しきい値より下**へ降ろしていた
        // （ADR-68 追補2）。FG-NET 実測（本番設定）でその帯の当たり率は **4.3%** しかなく、
        // 96% は「まず yes にならない対」だった。実機のユーザー回答でも「同じ人」と答えた対は
        // 下位 5% で 0.669＝引き上げても失う当たりはほぼ無い（ADR-150）。
        // 成長で離れた同一人物は、2 階層の束ね（ADR-61）と一覧からの明示操作で拾う。
        let facenet = FaceTuning.facenet
        #expect(facenet.mergeBandFloor(threshold: 0.50) == 0.50)
        // 校正でしきい値が上がったら、そちらに合わせる（帯が逆転しない）。
        #expect(facenet.mergeBandFloor(threshold: 0.60) == 0.60)

        let arc = FaceTuning.arcFace
        #expect(arc.mergeBandFloor(threshold: 0.35) == 0.40)
        #expect(arc.mergeBandFloor(threshold: 0.45) == 0.45)
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

    @Test("一括レビュー: 共起する対は候補にしない・基準と候補を除外できる")
    func batchReviewExclusions() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let a = FaceClustering.normalized([1, 0, 0])
        // ⚠️ 尋ねる下限がしきい値以上になった（ADR-150）。cos 0.52＝「自動では合流しない
        // （実効 0.58）が尋ねる価値はある」位置に置く。
        let b = FaceClustering.normalized([0.52, 0.854, 0])   // a と cos≈0.52
        // A: 3 枚。B: 3 枚（別写真）→ 候補になる。
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal(a, quality: 0.9)]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal(b, quality: 0.9)]) }
        // ⚠️ 尋ねる帯がしきい値以上になった（ADR-150）ので、少人数ライブラリではサイズ免除
        //（ADR-68）が効いてこの 2 つはその場で合流する。この検証の主題は候補の出し分けなので、
        // 割れている状態を明示的に作る。
        if let mergedID = await store.memberRefKeysByCluster()
            .first(where: { $0.value.contains("L-a0") && $0.value.contains("L-b0") })?.key {
            let bIDs = await store.facesForCluster(clusterID: mergedID)
                .filter { $0.refKey.hasPrefix("L-b") }.map(\.faceID)
            _ = await store.splitCluster(clusterID: mergedID, faceIDs: bIDs)
        }
        let item = await store.batchReviewItem(minFaces: 3)
        #expect(item != nil)
        #expect(item?.candidates.contains { $0.clusterID != item?.anchorClusterID } == true)

        // 候補を除外すると出てこない（同じ顔を出し続けない）。
        if let item {
            let excluded = await store.batchReviewItem(
                minFaces: 3, anchorClusterID: item.anchorClusterID,
                excludingCandidates: Set(item.candidates.map(\.clusterID)))
            #expect(excluded == nil)
            // 基準を除外すると別の人物が基準になる（「次の人へ」）。
            let next = await store.batchReviewItem(
                minFaces: 3, excludingAnchors: [item.anchorClusterID])
            #expect(next?.anchorClusterID != item.anchorClusterID)
        }

        // 共起（同じ写真に一緒に写る）が 1 回でもあれば候補にしない＝統合しても
        // 「1 枚に同じ人物が 2 回」にならない（ADR-68 追補4）。
        let store2 = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await store2.recordScan(refKey: "L-both\(i)",
                                    faces: [signal(a, quality: 0.9), signal(b, quality: 0.9)])
        }
        #expect(await store2.batchReviewItem(minFaces: 3) == nil)
    }

    @Test("統合ガード: 別名どうしと同一写真の共起は拒否し、共起は別人として学習する")
    func mergeGuards() async {
        // (1) 別々の名前 → 拒否（名前もクラスタも保たれる）。
        let s1 = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await s1.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await s1.recordScan(refKey: "L-b\(i)",
                                             faces: [signal(FaceClustering.normalized([0, 1, 0]))]) }
        await s1.rename(clusterID: 0, name: "太郎")
        await s1.rename(clusterID: 1, name: "花子")
        let r1 = await s1.mergeClusters(from: 1, into: 0)
        #expect(r1 == .differentNames)
        #expect(await s1.allClusters().count == 2)          // 統合されていない
        #expect(await s1.cluster(1)?.name == "花子")         // 名前も消えていない

        // (2) 同じ写真に一緒に写る → 拒否し、**別人として学習**する。
        let s2 = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 {
            await s2.recordScan(refKey: "L-both\(i)",
                                faces: [signal([1, 0, 0]), signal(FaceClustering.normalized([0, 1, 0]))])
        }
        let before = await s2.correctionCount()
        let r2 = await s2.mergeClusters(from: 1, into: 0)
        #expect(r2 == .samePhotoConflict)
        #expect(await s2.allClusters().count == 2)
        #expect(await s2.correctionCount() > before)         // notSame が記録された

        // (3) 問題ない対は従来どおり統合できる。
        let s3 = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<3 { await s3.recordScan(refKey: "L-x\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<3 { await s3.recordScan(refKey: "L-y\(i)",
                                             faces: [signal(FaceClustering.normalized([0, 1, 0]))]) }
        #expect(await s3.mergeClusters(from: 1, into: 0) == nil)
        #expect(await s3.allClusters().count == 1)
    }

    @Test("同一写真違反の修復: 最良の1顔を残し、外した顔を負例として学習する")
    func repairViolations() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        // 1 枚に同じ埋め込みの顔 2 つ（cannot-link で別クラスタ）＋別写真で各クラスタを育てる。
        await store.recordScan(refKey: "L-dup", faces: [signal([1, 0, 0], quality: 0.9),
                                                        signal([1, 0, 0], quality: 0.5)])
        for i in 0..<2 { await store.recordScan(refKey: "L-p\(i)", faces: [signal([1, 0, 0])]) }
        // 統合ガードを迂回して違反状態を作る（旧ビルドで起きた状態の再現）。
        await store.forceMergeForTesting(from: 1, into: 0)
        #expect(await store.qualityReport(minFaces: 1).samePhotoViolations == 1)

        let before = await store.correctionCount()
        let repaired = await store.repairSamePhotoViolations()
        #expect(repaired == 1)
        #expect(await store.qualityReport(minFaces: 1).samePhotoViolations == 0)
        #expect(await store.correctionCount() > before)   // 再発防止の負例が入る
    }

    // MARK: - クラスタ事後監査（ADR-69）

    @Test("事後監査: 2 人が混ざったクラスタを検出し、成長の広がりは検出しない")
    func clusterAuditDetectsMixture() {
        func spread(_ base: [Float], steps: Int, drift: Float) -> [[Float]] {
            // 少しずつ変わる「連続した帯」＝成長。
            (0..<steps).map { i -> [Float] in
                var v = base
                v[1] += drift * Float(i)
                return FaceClustering.normalized(v)
            }
        }
        let cfg = FaceTuning.facenet.auditConfig
        // (1) 同一人物の成長: 端から端まで離れていても**連続している**ので分割しない。
        let growth = spread([1, 0, 0], steps: 12, drift: 0.12)
        #expect(FaceClusterAudit.auditForSplit(embeddings: growth, config: cfg) == nil)

        // (2) 別人 2 人の混在: 2 つの離れた塊 → 検出する。
        let personA = spread([1, 0, 0], steps: 6, drift: 0.02)
        let personB = spread([0, 1, 0], steps: 6, drift: 0.02)
        let mixed = personA + personB
        let s = FaceClusterAudit.auditForSplit(embeddings: mixed, config: cfg)
        #expect(s != nil)
        // 正しく 2 分割できている（前半と後半が別の群）。
        if let s {
            let aIsFirstHalf = s.groupA.allSatisfy { $0 < 6 } || s.groupA.allSatisfy { $0 >= 6 }
            #expect(aIsFirstHalf)
            #expect(s.margin >= cfg.minMargin)
        }
    }

    @Test("事後監査: 同じ写真に両群の顔があれば分離度が甘くても検出する")
    func clusterAuditUsesHardEvidence() {
        // 分離が弱い（＝通常なら見送る）が、同じ写真に両群の顔が居る＝別人の決定的証拠。
        var vectors: [[Float]] = []
        for i in 0..<10 {
            var v: [Float] = [1, 0, 0]
            v[1] += 0.05 * Float(i)
            vectors.append(FaceClustering.normalized(v))
        }
        let keys = ["P1", "P1"] + (2..<10).map { "P\($0)" }   // 先頭 2 顔が同じ写真
        let cfg = FaceClusterAudit.Config(minMembers: 8, minGroupSize: 2,
                                          minMargin: 0.9, maxSeparation: 0.1)  // 通常判定は通らない
        let s = FaceClusterAudit.auditForSplit(embeddings: vectors, photoKeys: keys, config: cfg)
        // 決定的証拠があるときだけ提案される（無ければ nil）。
        let noEvidence = FaceClusterAudit.auditForSplit(embeddings: vectors, config: cfg)
        #expect(noEvidence == nil)
        if let s { #expect(s.hasHardEvidence) }
    }

    @Test("分割: 指定した顔が新しい人物に移り、負例として学習する")
    func splitClusterMovesFaces() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        let members = await store.faces(inCluster: 0)
        #expect(members.count == 4)
        let moving = members.suffix(2).map(\.faceID)
        let before = await store.correctionCount()
        let newID = await store.splitCluster(clusterID: 0, faceIDs: moving)
        #expect(newID != nil)
        #expect(await store.faces(inCluster: 0).count == 2)
        #expect(await store.faces(inCluster: newID!).count == 2)
        #expect(await store.correctionCount() > before)   // 再発防止の負例
    }

    @Test("ホームの列は 6 枚以上の人だけ（5 枚以内は「すべて表示」へ回す）")
    func carouselThreshold() {
        // 境界: 5 枚は出さない・6 枚は出す（「5 枚以内は重要人物ではない」＝実フィードバック）。
        #expect(PeopleEngine.minFacesForCarousel == 6)
        func person(_ id: Int, count: Int) -> PersonInfo {
            PersonInfo(clusterID: id, name: nil, count: count, coverRefKey: nil,
                       coverBoundingBox: nil, memberRefKeys: [])
        }
        let all = [person(1, count: 20), person(2, count: 6),
                   person(3, count: 5), person(4, count: 3)]
        let prominent = all.filter { $0.count >= PeopleEngine.minFacesForCarousel }
        #expect(prominent.map(\.clusterID) == [1, 2])
        // 残りは「すべて表示」に回る（レビュー母数の 3 枚以上は維持）。
        #expect(all.count - prominent.count == 2)
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

        // ⚠️ 現在は統合ガード（ADR-68 追補5）が同一写真の共起を拒否するので、
        // ここでは**旧ビルドで生じた違反状態**をガード迂回で再現し、検出できることを確かめる。
        #expect(await store.mergeClusters(from: 1, into: 0) == .samePhotoConflict)
        await store.forceMergeForTesting(from: 1, into: 0)
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

/// 「あらかじめ選んでおく」（ADR-153）。自動結合はしないが、ほぼ確実な対は選んだ状態で見せる。
@Suite("まとめて確認の事前選択")
struct BatchPreselectionTests {

    private func signal(_ v: [Float], quality: Float = 0.9) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: quality)
    }

    @Test("よく似た候補は選択済み・そうでない候補は未選択で出る")
    func highSimilarityCandidatesArePreselected() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let anchor = FaceClustering.normalized([1, 0, 0])
        // 0.95（ほぼ確実に同じ人）と 0.60（尋ねる価値はあるが確信はない）。
        let veryAlike = FaceClustering.normalized([0.95, 0.312, 0])
        let somewhat = FaceClustering.normalized([0.60, 0.8, 0])
        for i in 0..<3 { await store.recordScan(refKey: "L-a\(i)", faces: [signal(anchor)]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-b\(i)", faces: [signal(veryAlike)]) }
        for i in 0..<3 { await store.recordScan(refKey: "L-c\(i)", faces: [signal(somewhat)]) }
        // 少人数ではサイズ免除で合流してしまうので、割れている状態を明示的に作る。
        let map = await store.memberRefKeysByCluster()
        guard let anchorID = map.first(where: { $0.value.contains("L-a0") })?.key else {
            Issue.record("fixture: 基準クラスタが無い"); return
        }
        for prefix in ["L-b", "L-c"] {
            let ids = await store.facesForCluster(clusterID: anchorID)
                .filter { $0.refKey.hasPrefix(prefix) }.map(\.faceID)
            if !ids.isEmpty { _ = await store.splitCluster(clusterID: anchorID, faceIDs: ids) }
        }
        guard let item = await store.batchReviewItem(minFaces: 3, anchorClusterID: anchorID) else {
            Issue.record("候補が出ていない"); return
        }
        // 前提: 2 つの候補が出ている。
        #expect(item.candidates.count == 2, "候補数が想定と違う: \(item.candidates.count)")
        let veryAlikeCandidate = item.candidates.max { $0.similarity < $1.similarity }
        let somewhatCandidate = item.candidates.min { $0.similarity < $1.similarity }
        #expect(veryAlikeCandidate?.preselected == true, "ほぼ確実な対が選ばれていない")
        #expect(somewhatCandidate?.preselected == false, "確信の無い対まで選んでいる")
    }
}
