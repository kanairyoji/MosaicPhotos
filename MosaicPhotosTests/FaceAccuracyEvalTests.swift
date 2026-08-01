import AutoAlbumCore
import ImageIO
import MobileCLIPKit
import XCTest

/// 顔認識の**精度計測ハーネス**（ADR-55）。正解ラベル付きデータセットに対して
/// 本番同一パイプライン（検出→ゲート→アライメント→マルチクロップ埋め込み）を実行し、
/// クラスタリング品質（B-Cubed / ペア一致）と検証精度（TAR@FAR・最良しきい値）を出す。
///
/// 使い方:
/// 1. `scripts/fetch_face_eval_datasets.sh` を実行（FG-NET 取得＋own/ テンプレート生成）。
///    自前写真は `~/DEV/tmp/face-eval/own/images/`＋`labels.csv`（file,person[,age]）。
/// 2. 実行（時間がかかる・シミュレータ CPU で 1 枚 1〜2 秒。埋め込みはデータセット内に
///    キャッシュされ、2 回目以降は指標計算だけが走る）:
///    xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
///      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///      -only-testing:MosaicPhotosTests/FaceAccuracyEvalTests
/// 3. ログの `FACEEVAL:` 行が結果。しきい値スイープ表が「混入（precision）と分裂（recall）の
///    トレードオフ」を実データで示す。
///
/// ⚠️ シミュレータは CoreML が CPU 実行のため実機と数値が微差になり得るが、
///    相対比較（変更前後・しきい値間）には十分。
final class FaceAccuracyEvalTests: XCTestCase {

    private struct Sample {
        let file: String
        let person: String
        let age: Int?
        var embedding: [Float]
        var quality: Float
    }

    func testAccuracyOnDatasets() throws {
        let root = ProcessInfo.processInfo.environment["FACE_EVAL_DIR"]
            ?? "/Users/kanai/DEV/tmp/face-eval"
        var isDirectory: ObjCBool = false
        print("FACEEVAL: root=\(root) exists=\(FileManager.default.fileExists(atPath: root)) "
              + "model=\(FaceModel.modelBundled)")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory)
                          && isDirectory.boolValue,
                          "データセットなし: \(root)（scripts/fetch_face_eval_datasets.sh を実行）")
        try XCTSkipUnless(FaceModel.modelBundled, "顔モデル未同梱（scripts/build_facenet.sh で生成）")

        let datasets = (try FileManager.default.contentsOfDirectory(atPath: root))
            .filter { name in
                var d: ObjCBool = false
                let labels = "\(root)/\(name)/labels.csv"
                return FileManager.default.fileExists(atPath: "\(root)/\(name)/images", isDirectory: &d)
                    && d.boolValue && FileManager.default.fileExists(atPath: labels)
            }
            .sorted()
        try XCTSkipUnless(!datasets.isEmpty, "images/ + labels.csv を持つデータセットがない: \(root)")

        // FACE_EVAL_ONLY=lfw のように対象データセットを絞れる（長時間実行の分割用）。
        let only = ProcessInfo.processInfo.environment["FACE_EVAL_ONLY"]?
            .split(separator: ",").map(String.init)
        for dataset in datasets where only == nil || only!.contains(dataset) {
            try autoreleasepool {
                try evaluate(datasetDir: "\(root)/\(dataset)", name: dataset)
            }
        }

        // P4: ネガティブセット（顔のない画像）での偽陽性計測。labels.csv 不要・images のみ。
        let negativesDir = "\(root)/negatives/images"
        if FileManager.default.fileExists(atPath: negativesDir) {
            evaluateNegatives(imagesDir: negativesDir)
        }
    }

    /// 顔のない画像群で「顔として採用されてしまった数」＝偽陽性率を測る。
    private func evaluateNegatives(imagesDir: String) {
        let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif"]
        let urls = ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagesDir), includingPropertiesForKeys: nil)) ?? [])
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { return }
        let adapter = FacePerceptionAdapter()
        var images = 0
        var falseAccepted = 0
        var imagesWithFalse = 0
        for url in urls {
            autoreleasepool {
                guard let cg = Self.loadCGImage(url, maxPixel: 1024) else { return }
                images += 1
                let accepted = adapter.debugAnalyze(cg).filter(\.accepted).count
                if accepted > 0 {
                    imagesWithFalse += 1
                    falseAccepted += accepted
                    print("FACEEVAL[negatives]: 偽陽性 \(url.lastPathComponent) → \(accepted) 顔")
                }
            }
        }
        guard images > 0 else { return }
        print(String(format: "FACEEVAL[negatives]: 顔なし %d 枚中 誤採用あり %d 枚（%.1f%%）・誤採用顔 %d 個",
                     images, imagesWithFalse, Double(imagesWithFalse) / Double(images) * 100, falseAccepted))
    }

    // MARK: - 1 データセットの評価

    private func evaluate(datasetDir: String, name: String) throws {
        let labels = try Self.loadLabels(csvPath: "\(datasetDir)/labels.csv")
        guard !labels.isEmpty else {
            print("FACEEVAL[\(name)]: labels.csv が空 — スキップ")
            return
        }
        print("FACEEVAL[\(name)]: ラベル \(labels.count) 枚 — 埋め込み抽出開始")

        // 埋め込み（キャッシュあり）。パイプライン版数がキャッシュ名に入るので版上げで自動無効化。
        let (samples, rejected) = try extractEmbeddings(datasetDir: datasetDir, labels: labels)
        let detectionRate = Double(samples.count) / Double(labels.count)
        print(String(format: "FACEEVAL[%@]: 顔採用 %d/%d（%.1f%%）・棄却/未検出 %d",
                     name, samples.count, labels.count, detectionRate * 100, rejected))
        guard samples.count >= 10 else {
            print("FACEEVAL[\(name)]: 採用顔が少なすぎるため指標を出せない")
            return
        }
        reportAcceptanceByAge(samples: samples, labels: labels, name: name)

        // --- 検証（ペア類似度） ---
        let skipVerify = ProcessInfo.processInfo.environment["FACE_EVAL_SKIP_VERIFY"] == "1"
        var sameSims: [Float] = []
        var differentSims: [Float] = []
        var sameByAgeGap: [String: [Float]] = [:]
        var childDifferentSims: [Float] = []   // 別人×両方 12 歳以下＝「兄弟の難しさ」の代理
        for i in samples.indices where !skipVerify {
            for j in (i + 1)..<samples.count {
                let sim = FaceClustering.dot(samples[i].embedding, samples[j].embedding)
                if samples[i].person == samples[j].person {
                    sameSims.append(sim)
                    if let a = samples[i].age, let b = samples[j].age {
                        sameByAgeGap[Self.ageGapBucket(abs(a - b)), default: []].append(sim)
                    }
                } else {
                    differentSims.append(sim)
                    if let a = samples[i].age, let b = samples[j].age, a <= 12, b <= 12 {
                        childDifferentSims.append(sim)
                    }
                }
            }
        }
        if let v = FaceEvalMetrics.verificationScore(sameSims: sameSims, differentSims: differentSims) {
            print(String(format: "FACEEVAL[%@]: 検証 同一%d/別人%d 平均 同一=%.3f 別人=%.3f",
                         name, v.samePairs, v.differentPairs, v.sameMean, v.differentMean))
            print(String(format: "FACEEVAL[%@]: TAR@FAR1%%=%.1f%% TAR@FAR0.1%%=%.1f%% 最良F1しきい値=%.2f（F1=%.3f）",
                         name, v.tarAtFar01 * 100, v.tarAtFar001 * 100, v.bestF1Threshold, v.bestF1))
        }
        for (bucket, sims) in sameByAgeGap.sorted(by: { $0.key < $1.key }) {
            let mean = sims.reduce(0.0) { $0 + Double($1) } / Double(sims.count)
            print(String(format: "FACEEVAL[%@]: 同一人物・年齢差%@ ペア%d 平均類似度=%.3f",
                         name, bucket, sims.count, mean))
        }
        if !childDifferentSims.isEmpty {
            let mean = childDifferentSims.reduce(0.0) { $0 + Double($1) } / Double(childDifferentSims.count)
            print(String(format: "FACEEVAL[%@]: 別人・両者12歳以下（兄弟の代理）ペア%d 平均類似度=%.3f",
                         name, childDifferentSims.count, mean))
        }

        // --- クラスタリング（本番と同じ FaceClustering・品質降順＝再クラスタと同順） ---
        // バリアント: ベースライン / P2 自動プロトタイプ（K=5）/ P2＋P3 連鎖統合（数種のしきい値）。
        let truth = Dictionary(uniqueKeysWithValues: samples.map { ($0.file, $0.person) })
        let ordered = samples.sorted { $0.quality > $1.quality }
        let faces = ordered.map { (faceID: $0.file, embedding: $0.embedding) }
        let qualities = Dictionary(uniqueKeysWithValues: ordered.map { ($0.file, $0.quality) })

        func score(clusters: [FaceClustering.Cluster], mergePlan: [Int: Int] = [:]) -> FaceEvalMetrics.ClusteringScore? {
            var assignments: [String: Int] = [:]
            var nextSingleton = -1
            for sample in samples { assignments[sample.file] = nextSingleton; nextSingleton -= 1 }
            for c in clusters {
                let finalID = mergePlan[c.id] ?? c.id
                for fid in c.faceIDs { assignments[fid] = finalID }
            }
            return FaceEvalMetrics.clusteringScore(assignments: assignments, truth: truth)
        }
        func printRow(_ label: String, _ s: FaceEvalMetrics.ClusteringScore?) {
            guard let s else { return }
            print(String(format: "FACEEVAL[%@]:  %@  B3 P=%.3f R=%.3f F1=%.3f | pair F1=%.3f | clusters=%d",
                         name, label, s.bcubedPrecision, s.bcubedRecall, s.bcubedF1, s.pairF1, s.clusterCount))
        }

        // 大規模データセット（LFW 等）は貪欲クラスタリングが O(顔数×クラスタ数×次元) で
        // 重い（デバッグビルド）ため、確認に必要な構成へグリッドを縮小する。
        let reducedGrid = samples.count > 2000
        print("FACEEVAL[\(name)]: === ベースライン（重心のみ） vs P2 自動プロトタイプ（K=5） ===")
        let baseThresholds: [Float] = reducedGrid ? [0.55, 0.60] : [0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
        for threshold in baseThresholds {
            let base = FaceClustering.clusterAll(faces, threshold: threshold, qualityFloor: 0.40,
                                                 qualities: qualities)
            printRow(String(format: "base  thr=%.2f", threshold), score(clusters: base))
            if !reducedGrid {
                let proto = FaceClustering.clusterAll(faces, threshold: threshold, qualityFloor: 0.40,
                                                      qualities: qualities, autoPrototypeLimit: 5)
                printRow(String(format: "proto thr=%.2f", threshold), score(clusters: proto))
            }
        }

        print("FACEEVAL[\(name)]: === 系統1 バリアント（ADR-57・推移性なしで再現率回復を狙う） ===")
        // A) マージンゲート付き貪欲。
        for thr in [Float(0.55), 0.60] {
            for margin in (reducedGrid ? [Float(0.05)] : [Float(0.05), 0.10]) {
                let clusters = FaceClusteringVariants.marginGatedCluster(
                    faces, threshold: thr, margin: margin, qualityFloor: 0.40, qualities: qualities)
                printRow(String(format: "marginGated thr=%.2f m=%.2f", thr, margin),
                         score(clusters: clusters))
            }
        }
        // B) 二段階＋比率テスト（縮小グリッドでは省略＝FG-NET で敗退済みの確認不要）。
        for core in (reducedGrid ? [] : [Float(0.65), 0.70]) {
            for attach in [Float(0.50), 0.55] {
                for margin in [Float(0.05), 0.10] {
                    let clusters = FaceClusteringVariants.twoStageCluster(
                        faces, coreThreshold: core, attachThreshold: attach, margin: margin,
                        qualityFloor: 0.40, qualities: qualities)
                    printRow(String(format: "twoStage c=%.2f a=%.2f m=%.2f", core, attach, margin),
                             score(clusters: clusters))
                }
            }
        }
        // C) ロバスト重心（中央値・2 パス）。
        for thr in (reducedGrid ? [Float(0.60)] : [Float(0.55), 0.60, 0.65]) {
            let clusters = FaceClusteringVariants.medianRefinedCluster(
                faces, threshold: thr, qualityFloor: 0.40, qualities: qualities)
            printRow(String(format: "median thr=%.2f", thr), score(clusters: clusters))
        }

        // D) サイズ適応マージン（ADR-58）: 現行採用（margin0.05・thr0.55）にサイズ適応を重ねる。
        print("FACEEVAL[\(name)]: === D サイズ適応マージン（現行=margin0.05 に上乗せ） ===")
        // 参照: 現行本番構成（固定マージンのみ）。
        printRow("current margin0.05 thr0.55", score(clusters: FaceClustering.clusterAll(
            faces, threshold: 0.55, qualityFloor: 0.40, qualities: qualities, assignMargin: 0.05)))
        // 縮小グリッド（LFW）は FG-NET 最良近傍のみ確認（退行チェック）。
        let sizeGrid: [(Float, Float)] = reducedGrid
            ? [(0.50, 0.05), (0.50, 0.10)]
            : [(0.50, 0.05), (0.50, 0.10), (0.50, 0.15), (0.55, 0.05), (0.55, 0.10), (0.55, 0.15)]
        for (thr, sizeMax) in sizeGrid {
            let clusters = FaceClustering.clusterAll(
                faces, threshold: thr, qualityFloor: 0.40, qualities: qualities,
                assignMargin: 0.05, sizeAdaptiveMarginMax: sizeMax)
            printRow(String(format: "sizeAdapt thr=%.2f m0.05 smax=%.2f", thr, sizeMax),
                     score(clusters: clusters))
        }

        // E) 純度の事後検査（外れ値除去・ADR-59）: 現行本番構成（thr0.50/margin0.05/size0.10）の
        // 出力に外れ値除去を重ねる。混入を事後的に抜いて純度を上げられるか。
        print("FACEEVAL[\(name)]: === E 外れ値除去（現行本番構成の後段） ===")
        let embByID = Dictionary(uniqueKeysWithValues: samples.map { ($0.file, $0.embedding) })
        let prod = FaceClustering.clusterAll(faces, threshold: 0.50, qualityFloor: 0.40,
                                             qualities: qualities, assignMargin: 0.05,
                                             sizeAdaptiveMarginMax: 0.10)
        printRow("prod (no prune)", score(clusters: prod))
        for factor in [Float(1.5), 1.8, 2.2] {
            let pruned = FaceClusteringVariants.pruneOutliers(prod, embeddings: embByID,
                                                              dropFactor: factor, minCount: 4)
            printRow(String(format: "prune factor=%.1f", factor), score(clusters: pruned))
        }
        // === 年齢を使ったクラスタリング（FG-NET の年齢ラベルで上限効果を計測・ADR-60） ===
        // 年齢は「推定で得られる想定の入力」として使う（人物ラベルは評価にのみ使用＝cheat しない）。
        let ageByFile = Dictionary(uniqueKeysWithValues: samples.compactMap { sm in sm.age.map { (sm.file, $0) } })
        if ageByFile.count == samples.count, !reducedGrid {
            print("FACEEVAL[\(name)]: === 年齢クラスタリング（年齢を完璧に知っていた場合の上限） ===")
            let prod = FaceClustering.clusterAll(faces, threshold: 0.50, qualityFloor: 0.40,
                                                 qualities: qualities, assignMargin: 0.05,
                                                 sizeAdaptiveMarginMax: 0.10)
            printRow("prod（年齢不使用・現行本番）", score(clusters: prod))

            // 案 X-1: 年齢層で顔を分割→各層内で現行クラスタリング（層をまたぐ統合なし）。
            func ageBand(_ a: Int) -> Int {
                switch a { case ..<3: return 0; case ..<10: return 1; case ..<20: return 2
                           case ..<45: return 3; default: return 4 }
            }
            var byBand: [Int: [(faceID: String, embedding: [Float])]] = [:]
            for f in faces { byBand[ageBand(ageByFile[f.faceID]!), default: []].append(f) }
            var bandClusters: [FaceClustering.Cluster] = []
            for (band, bandFaces) in byBand {
                let cs = FaceClustering.clusterAll(bandFaces, threshold: 0.50, qualityFloor: 0.40,
                                                   qualities: qualities, assignMargin: 0.05,
                                                   sizeAdaptiveMarginMax: 0.10)
                for c in cs {
                    var offset = c            // 層をまたぐと別クラスタ扱いにするため ID をずらす
                    offset.id = c.id + band * 100_000
                    bandClusters.append(offset)
                }
            }
            printRow("X-1 年齢層で分類→各層内", score(clusters: bandClusters))

            // 案 X-2: 年齢連結。現行クラスタの後、代表類似度が中程度（[thr-0.20, thr)）かつ
            // 年齢範囲が重なる/近い（±3年）クラスタ対を統合＝成長チェーンを繋ぐ。
            var ageRange: [Int: (lo: Int, hi: Int)] = [:]
            for c in prod {
                let ages = c.faceIDs.compactMap { ageByFile[$0] }
                if let mn = ages.min(), let mx = ages.max() { ageRange[c.id] = (mn, mx) }
            }
            func ageConnectable(_ a: Int, _ b: Int) -> Bool {
                guard let ra = ageRange[a], let rb = ageRange[b] else { return false }
                return max(ra.lo, rb.lo) <= min(ra.hi, rb.hi) + 3   // 重なり or 3年以内の隣接
            }
            for chainThr in [Float(0.35), 0.40, 0.45] {
                let plan = FaceClustering.chainMergePlan(clusters: prod, threshold: chainThr) { x, y in
                    !ageConnectable(x, y)   // 年齢が連続しない対は統合をブロック
                }
                printRow(String(format: "X-2 年齢連結 chain=%.2f", chainThr),
                         score(clusters: prod, mergePlan: plan))
            }
        }

        // === 2 階層（人物=複数クラスタの束）vs 融合（人物=1 重心）の識別精度（ADR-61） ===
        // 各人物の顔を登録80%/クエリ20%に決定的分割（file 名ソート・index%5==4 をクエリ）。
        // 登録顔から人物モデルを 2 方式で作り、クエリ顔を全人物へ argmax 帰属→正解人物率を比較。
        // 2 階層が融合を上回れば「クラスタを別々に保ち上位で束ねる」設計の優位が実証される。
        evaluatePersonGrouping(samples: samples, name: name, temporal: false)   // 年齢混在分割（実運用に近い）
        if samples.contains(where: { $0.age != nil }) {
            evaluatePersonGrouping(samples: samples, name: name, temporal: true)   // 時系列分割（成長差を跨ぐ）
        }

        print("FACEEVAL[\(name)]: 完了")
    }

    // MARK: - 2 階層 vs 融合の識別精度（ADR-61）

    private func evaluatePersonGrouping(samples: [Sample], name: String, temporal: Bool) {
        var byPerson: [String: [Sample]] = [:]
        for sm in samples { byPerson[sm.person, default: []].append(sm) }

        var multiPersons: [FacePersonGrouping.PersonModel] = []   // 2 階層（複数クラスタ）
        var fusedPersons: [FacePersonGrouping.PersonModel] = []   // 融合（1 重心）
        var queries: [(embedding: [Float], truth: Int, age: Int?)] = []
        var personID = 0
        for (person, group) in byPerson.sorted(by: { $0.key < $1.key }) {
            // temporal: 年齢昇順で前80%登録・後20%クエリ（若い頃を登録→成長後を識別）。
            // mixed: file 名ソート・index%5==4 をクエリ（全時期が登録に混在＝実運用に近い）。
            let sorted = temporal
                ? group.sorted { ($0.age ?? 0, $0.file) < ($1.age ?? 0, $1.file) }
                : group.sorted { $0.file < $1.file }
            guard sorted.count >= 3 else { continue }
            var train: [Sample] = [], query: [Sample] = []
            if temporal {
                let split = Int(Double(sorted.count) * 0.8)
                train = Array(sorted[..<split]); query = Array(sorted[split...])
            } else {
                for (i, sm) in sorted.enumerated() { if i % 5 == 4 { query.append(sm) } else { train.append(sm) } }
            }
            guard train.count >= 2, !query.isEmpty else { continue }
            personID += 1
            // 2 階層: 登録顔を人物内クラスタリング（現行本番構成）→各クラスタ重心を代表に。
            let clusters = FaceClustering.clusterAll(
                train.map { (faceID: $0.file, embedding: $0.embedding) },
                threshold: 0.50, qualityFloor: 0.40,
                qualities: Dictionary(uniqueKeysWithValues: train.map { ($0.file, $0.quality) }),
                assignMargin: 0.05, sizeAdaptiveMarginMax: 0.10)
            let reps = clusters.map(\.centroid)
            multiPersons.append(.init(personID: personID, clusterReps: reps.isEmpty ? [train[0].embedding] : reps))
            // 融合: 登録顔全体を 1 重心へ。
            let fused = FacePersonGrouping.fusedRep(train.map(\.embedding)) ?? train[0].embedding
            fusedPersons.append(.init(personID: personID, clusterReps: [fused]))
            for q in query { queries.append((q.embedding, personID, q.age)) }
        }
        guard queries.count >= 20 else {
            print("FACEEVAL[\(name)]: 識別評価スキップ（クエリ \(queries.count) 件）")
            return
        }

        func identifyRate(_ persons: [FacePersonGrouping.PersonModel]) -> (all: Double, byAge: [String: (hit: Int, n: Int)]) {
            var hit = 0
            var byAge: [String: (hit: Int, n: Int)] = [:]
            for q in queries {
                let pred = FacePersonGrouping.nearestPerson(q.embedding, persons: persons)?.personID
                let correct = pred == q.truth
                if correct { hit += 1 }
                if let age = q.age {
                    let bucket = Self.ageBucket(age)
                    var e = byAge[bucket] ?? (0, 0)
                    e.n += 1; if correct { e.hit += 1 }
                    byAge[bucket] = e
                }
            }
            return (Double(hit) / Double(queries.count), byAge)
        }

        let multi = identifyRate(multiPersons)
        let fused = identifyRate(fusedPersons)
        print("FACEEVAL[\(name)]: === 2 階層 vs 融合の人物識別精度・\(temporal ? "時系列分割(若→成長後)" : "年齢混在分割(実運用)")（クエリ \(queries.count) 件・\(multiPersons.count) 人） ===")
        print(String(format: "FACEEVAL[%@]:  融合（人物=1重心）   識別率=%.1f%%", name, fused.all * 100))
        print(String(format: "FACEEVAL[%@]:  2階層（人物=複数クラスタ）識別率=%.1f%%", name, multi.all * 100))
        for bucket in multi.byAge.keys.sorted() {
            let m = multi.byAge[bucket]!, f = fused.byAge[bucket] ?? (0, 0)
            print(String(format: "FACEEVAL[%@]:   年齢%@ クエリ%d: 融合=%.0f%% → 2階層=%.0f%%",
                         name, bucket, m.n,
                         f.n > 0 ? Double(f.hit) / Double(f.n) * 100 : 0,
                         Double(m.hit) / Double(m.n) * 100))
        }
    }

    // MARK: - 埋め込み抽出（キャッシュつき）

    private func extractEmbeddings(datasetDir: String,
                                   labels: [(file: String, person: String, age: Int?)])
        throws -> (samples: [Sample], rejected: Int) {
        let cacheURL = URL(fileURLWithPath: "\(datasetDir)/embeddings-v\(PeopleEngine.faceScanVersion).json")
        var cache: [String: [Float]] = [:]
        var qualityCache: [String: Float] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode(CacheFile.self, from: data) {
            cache = decoded.embeddings
            qualityCache = decoded.qualities
        }

        let adapter = FacePerceptionAdapter()
        var samples: [Sample] = []
        var rejected = 0
        var processed = 0
        var cacheDirty = false
        for label in labels {
            if let cached = cache[label.file] {
                if cached.isEmpty {
                    rejected += 1   // 前回「顔なし/棄却」だった画像
                } else {
                    samples.append(Sample(file: label.file, person: label.person, age: label.age,
                                          embedding: cached, quality: qualityCache[label.file] ?? 1))
                }
                continue
            }
            autoreleasepool {
                let url = URL(fileURLWithPath: "\(datasetDir)/images/\(label.file)")
                guard let cg = Self.loadCGImage(url, maxPixel: 1024) else {
                    cache[label.file] = []; cacheDirty = true; rejected += 1
                    return
                }
                // 1 画像 1 人物前提（FG-NET 等）: 採用顔のうち最大の顔を主対象とする。
                let results = adapter.debugAnalyzeWithEmbeddings(cg)
                let best = results
                    .filter { $0.embedding != nil }
                    .max { $0.report.pixelSize.width < $1.report.pixelSize.width }
                if let best, let vec = best.embedding, vec.allSatisfy(\.isFinite) {
                    cache[label.file] = vec
                    qualityCache[label.file] = best.quality ?? best.report.adjustedQuality
                    samples.append(Sample(file: label.file, person: label.person, age: label.age,
                                          embedding: vec,
                                          quality: qualityCache[label.file]!))
                } else {
                    cache[label.file] = []
                    rejected += 1
                }
                cacheDirty = true
            }
            processed += 1
            if processed % 100 == 0 {
                print("FACEEVAL: … \(processed) 枚処理（採用 \(samples.count)）")
                saveCache(cacheURL, embeddings: cache, qualities: qualityCache)
                cacheDirty = false
            }
        }
        if cacheDirty { saveCache(cacheURL, embeddings: cache, qualities: qualityCache) }
        return (samples, rejected)
    }

    private struct CacheFile: Codable {
        var embeddings: [String: [Float]]
        var qualities: [String: Float]
    }

    private func saveCache(_ url: URL, embeddings: [String: [Float]], qualities: [String: Float]) {
        if let data = try? JSONEncoder().encode(CacheFile(embeddings: embeddings, qualities: qualities)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 年齢バケット別の顔採用率（成長期の写真がゲートでどれだけ弾かれているかの可視化）。
    private func reportAcceptanceByAge(samples: [Sample],
                                       labels: [(file: String, person: String, age: Int?)],
                                       name: String) {
        let acceptedFiles = Set(samples.map(\.file))
        var total: [String: Int] = [:]
        var accepted: [String: Int] = [:]
        for label in labels {
            guard let age = label.age else { continue }
            let bucket = Self.ageBucket(age)
            total[bucket, default: 0] += 1
            if acceptedFiles.contains(label.file) { accepted[bucket, default: 0] += 1 }
        }
        for (bucket, count) in total.sorted(by: { $0.key < $1.key }) {
            let acceptedCount = accepted[bucket] ?? 0
            print(String(format: "FACEEVAL[%@]: 年齢%@ 採用 %d/%d（%.0f%%）",
                         name, bucket, acceptedCount, count,
                         Double(acceptedCount) / Double(count) * 100))
        }
    }

    // MARK: - Helpers

    private static func loadLabels(csvPath: String) throws -> [(file: String, person: String, age: Int?)] {
        let text = try String(contentsOfFile: csvPath, encoding: .utf8)
        var out: [(String, String, Int?)] = []
        // ⚠️ Swift は "\r\n" を 1 書記素として扱うため split(separator: "\n") は CRLF に
        // マッチしない（1002 行の CSV が丸ごと 1 行になり 0 件パースの実障害）。newlines で分割する。
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let cols = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 2, cols[0].lowercased() != "file" else { continue }
            out.append((cols[0], cols[1], cols.count >= 3 ? Int(cols[2]) : nil))
        }
        return out
    }

    private static func ageBucket(_ age: Int) -> String {
        switch age {
        case ..<3: return "0-2"
        case ..<6: return "3-5"
        case ..<13: return "6-12"
        case ..<20: return "13-19"
        default: return "20+"
        }
    }

    private static func ageGapBucket(_ gap: Int) -> String {
        switch gap {
        case ..<3: return "0-2年"
        case ..<6: return "3-5年"
        case ..<11: return "6-10年"
        case ..<21: return "11-20年"
        default: return "21年+"
        }
    }

    private static func loadCGImage(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
