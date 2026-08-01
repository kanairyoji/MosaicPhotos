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
        print("FACEEVAL[\(name)]: 完了")
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
