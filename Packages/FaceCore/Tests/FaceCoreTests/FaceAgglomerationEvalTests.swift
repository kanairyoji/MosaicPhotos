import Foundation
import Testing
@testable import FaceCore

/// **夜間の再クラスタ: 逐次方式 vs 平均連結（ADR-217）の計測**（FG-NET / LFW / PIPA）。
///
/// どちらも本番の `rebuildClusters` と同じ前後処理（品質フロア・第2パス・同一写真の決まり）で
/// 比べる。名前・確認の無い初回の状態（種なし）。
/// - FG-NET / LFW: `FaceAccuracyEvalTests` の埋め込みキャッシュ（`embeddings-v5.json`）
/// - PIPA: `scripts/fetch_pipa_eval.py` で取った写真の顔（`faces-auraface-v1-r100.json`。
///   同じ写真に複数人が写る＝同一写真の決まりが効く唯一のデータ）
/// 無ければスキップ。結果は `~/DEV/tmp/face-eval/agglomeration-latest.txt`。
@Suite("夜間の再クラスタ: 逐次 vs 平均連結（計測）", .serialized)
struct FaceAgglomerationEvalTests {

    static let root = ProcessInfo.processInfo.environment["FACE_EVAL_DIR"]
        ?? (NSHomeDirectory() + "/DEV/tmp/face-eval")
    static let pipaRoot = NSHomeDirectory() + "/DEV/tmp/face-eval-pipa"
    static var available: Bool {
        FileManager.default.fileExists(atPath: root + "/fgnet/embeddings-v5.json")
    }
    static let outputPath = root + "/agglomeration-latest.txt"

    struct Face {
        let id: String
        let photo: String
        let truth: String?
        let embedding: [Float]
        let quality: Float
        var age: Int? = nil
        var date: Date? = nil
    }

    static func emit(_ line: String) {
        print(line)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: outputPath) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    struct CacheFile: Decodable {
        let embeddings: [String: [Float]]
        let qualities: [String: Float]?
    }

    static func loadCrops(_ dataset: String, version: Int = 5) throws -> [Face] {
        let dir = root + "/" + dataset
        let cache = try JSONDecoder().decode(
            CacheFile.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/embeddings-v\(version).json")))
        let text = try String(contentsOfFile: dir + "/labels.csv", encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let c = line.split(separator: ",").map(String.init)
            guard c.count >= 2, let e = cache.embeddings[c[0]], !e.isEmpty else { return nil }
            return Face(id: c[0], photo: c[0], truth: c[1], embedding: e,
                        quality: cache.qualities?[c[0]] ?? 1,
                        age: c.count > 2 ? Int(c[2]) : nil)
        }
    }

    struct PipaFace: Decodable {
        let id: String
        let photo: String
        let embedding: [Float]
        let quality: Float
        let truth: String?
        let date: String?
    }

    static func loadPIPA() throws -> [Face]? {
        let path = pipaRoot + "/faces-auraface-v1-r100.json"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let rows = try JSONDecoder().decode([PipaFace].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return rows.map { Face(id: $0.id, photo: $0.photo, truth: $0.truth, embedding: $0.embedding,
                               quality: $0.quality, date: $0.date.flatMap { parser.date(from: $0) }) }
    }

    nonisolated(unsafe) static var tuning = FaceTuning.arcFace
    static let floor = FaceStore.qualityFloor

    /// 現行: 品質降順に `place`（同一写真を除外）→ 第2パス。
    static func sequential(_ faces: [Face]) -> [String: Int] {
        var clustering = FaceClusteringSetup.make(
            threshold: tuning.clusterThreshold, qualityFloor: floor, tuning: tuning,
            seeds: [], minimumNextID: 0, anchoredClusterIDs: [])
        let pending = faces.sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.id < $1.id }
        var assignment: [String: Int] = [:]
        var used: [String: Set<Int>] = [:]
        for f in pending {
            let p = clustering.place(faceID: f.id, embedding: f.embedding, quality: f.quality,
                                     excludedClusterIDs: used[f.photo] ?? [])
            assignment[f.id] = p.clusterID
            if p.clusterID >= 0 { used[f.photo, default: []].insert(p.clusterID) }
        }
        secondPass(pending, clustering: &clustering, assignment: &assignment, used: &used)
        return assignment
    }

    /// 新方式: フロア以上を平均連結でまとめる → 本番と同じ重み付き和で人物を作る → 第2パス。
    static func agglomerative(_ faces: [Face], config: FaceAgglomeration.Config) -> [String: Int] {
        let pending = faces.sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.id < $1.id }
        let byID = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
        let groups = FaceAgglomeration.cluster(
            faces: pending.filter { $0.quality >= config.inclusionFloor }
                .map { .init(faceID: $0.id, photo: $0.photo) },
            seeds: [], embedding: { byID[$0]?.embedding }, captureDate: { byID[$0]?.date },
            config: config)
        var clusters: [FaceClustering.Cluster] = []
        var assignment: [String: Int] = [:]
        var used: [String: Set<Int>] = [:]
        for (index, group) in groups.enumerated() {
            var sum: [Float] = []
            var count = 0
            for id in group.faceIDs {
                guard let f = byID[id] else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: f.embedding.count) }
                let added = FaceClustering.adding(f.embedding, toSum: sum, count: count, quality: f.quality)
                sum = added.sum; count = added.count
                assignment[id] = index
                used[f.photo, default: []].insert(index)
            }
            guard count > 0 else { continue }
            clusters.append(.init(id: index, centroid: FaceClustering.normalized(sum), sum: sum,
                                  count: count, faceIDs: group.faceIDs))
        }
        var clustering = FaceClusteringSetup.make(
            threshold: tuning.clusterThreshold, qualityFloor: floor, tuning: tuning,
            seeds: clusters, minimumNextID: groups.count, anchoredClusterIDs: [])
        secondPass(pending, clustering: &clustering, assignment: &assignment, used: &used,
                   below: config.inclusionFloor)
        return assignment
    }

    static func secondPass(_ pending: [Face], clustering: inout FaceClustering,
                           assignment: inout [String: Int], used: inout [String: Set<Int>],
                           below: Float = floor) {
        for f in pending where (assignment[f.id] ?? -1) < 0 && f.quality < below {
            let cid = clustering.assignMembershipOnly(faceID: f.id, embedding: f.embedding,
                                                      excludedClusterIDs: used[f.photo] ?? [],
                                                      threshold: tuning.secondPassThreshold)
            if cid >= 0 { assignment[f.id] = cid; used[f.photo, default: []].insert(cid) }
        }
    }

    static func score(_ assignment: [String: Int], _ faces: [Face]) -> FaceEvalMetrics.ClusteringScore? {
        var unique = -1_000_000
        var a: [String: Int] = [:]
        var truth: [String: String] = [:]
        for f in faces {
            guard let t = f.truth else { continue }
            truth[f.id] = t
            let cid = assignment[f.id] ?? -1
            if cid >= 0 { a[f.id] = cid } else { a[f.id] = unique; unique -= 1 }
        }
        return FaceEvalMetrics.clusteringScore(assignments: a, truth: truth)
    }

    /// 同じ写真の 2 つの顔が同じ人物に入った数（0 でなければならない）。
    static func samePhotoViolations(_ assignment: [String: Int], _ faces: [Face]) -> Int {
        var seen: [String: Set<Int>] = [:]
        var violations = 0
        for f in faces {
            guard let cid = assignment[f.id], cid >= 0 else { continue }
            if !seen[f.photo, default: []].insert(cid).inserted { violations += 1 }
        }
        return violations
    }

    static func line(_ label: String, _ s: FaceEvalMetrics.ClusteringScore?, violations: Int) -> String {
        guard let s else { return "\(label): (なし)" }
        return String(format: "%@: P=%.4f R=%.4f F1=%.4f・人物ごとの純度 最悪 %.3f／下位25%% %.3f・純度<0.8 の人物 %d・分裂 %.2f・同一写真の違反 %d",
                      label, s.bcubedPrecision, s.bcubedRecall, s.bcubedF1,
                      s.worstIdentityPrecision, s.p25IdentityPrecision,
                      s.identitiesBelow80Precision, s.clustersPerIdentity, violations)
    }

    @Test("逐次方式と平均連結を、しきい値を振って比べる", .enabled(if: available))
    func compare() throws {
        try? FileManager.default.removeItem(atPath: Self.outputPath)
        var sets: [(String, [Face])] = [("fgnet", try Self.loadCrops("fgnet")),
                                        ("lfw", try Self.loadCrops("lfw"))]
        if let pipa = try Self.loadPIPA() { sets.append(("pipa", pipa)) }
        for (name, faces) in sets {
            let seq = Self.sequential(faces)
            Self.emit(Self.line("AGG[\(name)] 現行（逐次）", Self.score(seq, faces),
                                violations: Self.samePhotoViolations(seq, faces)))
            for micro: Float in [0.50, 0.55, 0.60] {
                for bar: Float in [0.30, 0.35, 0.40, 0.45] {
                    let start = Date()
                    let agg = Self.agglomerative(faces, config: .init(microThreshold: micro, mergeBar: bar))
                    let elapsed = Date().timeIntervalSince(start)
                    Self.emit(Self.line(String(format: "AGG[%@] 平均連結 小さな山 %.2f・まとめる線 %.2f（%.1f 秒）",
                                               name, micro, bar, elapsed),
                                        Self.score(agg, faces),
                                        violations: Self.samePhotoViolations(agg, faces)))
                }
            }
        }
    }

    /// 旧モデル（facenet・v4 キャッシュ）のプロファイル値を決めるための掃引。
    @Test("facenet（旧モデル）でも、まとめる線を決める",
          .enabled(if: FileManager.default.fileExists(atPath: root + "/fgnet/embeddings-v4.json")))
    func compareFacenet() throws {
        Self.tuning = .facenet
        defer { Self.tuning = .arcFace }
        for name in ["fgnet", "lfw"] {
            let faces = try Self.loadCrops(name, version: 4)
            let seq = Self.sequential(faces)
            Self.emit(Self.line("AGG-FACENET[\(name)] 現行（逐次）", Self.score(seq, faces),
                                violations: Self.samePhotoViolations(seq, faces)))
            for bar: Float in [0.45, 0.50, 0.55, 0.60] {
                let agg = Self.agglomerative(faces, config: .init(microThreshold: 0.65, mergeBar: bar))
                Self.emit(Self.line(String(format: "AGG-FACENET[%@] 平均連結 小さな山 0.65・まとめる線 %.2f", name, bar),
                                    Self.score(agg, faces), violations: Self.samePhotoViolations(agg, faces)))
            }
        }
    }

    // MARK: - 実機相当の品質（ADR-220）

    /// ⚠️ シミュレータでは OS の顔品質が取れず 1.0 になる（本番は nil を 1.0 として扱う）。
    /// 計測キャッシュの品質は「1.0 × 減点」なので、Mac で取った OS の品質
    /// （`scripts/os_face_quality.swift` → `os-quality.json`）と合成して実機の値を再現する。
    /// 減点は上限（`profileCap`）か係数なので: 上限がかかった顔は min(OS, 上限)、それ以外は OS × 係数。
    static func deviceLike(_ faces: [Face], osQualityPath: String) -> [Face]? {
        guard let data = FileManager.default.contents(atPath: osQualityPath),
              let os = try? JSONDecoder().decode([String: Float].self, from: data) else { return nil }
        let cap = FaceQualityGate.profileCap
        return faces.map { f in
            guard let raw = os[f.id] else { return f }
            let q = f.quality <= cap + 0.0001 ? min(raw, f.quality) : raw * f.quality
            return Face(id: f.id, photo: f.photo, truth: f.truth, embedding: f.embedding,
                        quality: q, age: f.age, date: f.date)
        }
    }

    @Test("実機相当の品質で、平均連結に入れる線（0.40 → 0.10）を比べる", .enabled(if: available))
    func inclusionFloorOnDeviceQuality() throws {
        var sets: [(String, [Face]?)] = [
            ("fgnet", Self.deviceLike(try Self.loadCrops("fgnet"), osQualityPath: Self.root + "/fgnet/os-quality.json")),
            ("lfw", Self.deviceLike(try Self.loadCrops("lfw"), osQualityPath: Self.root + "/lfw/os-quality.json")),
        ]
        if let pipa = try Self.loadPIPA() {
            sets.append(("pipa", Self.deviceLike(pipa, osQualityPath: Self.pipaRoot + "/os-quality.json")))
        }
        for (name, maybe) in sets {
            guard let faces = maybe else { Self.emit("FLOOR[\(name)]: os-quality.json が無い"); continue }
            let below = faces.filter { $0.quality < FaceStore.qualityFloor }.count
            Self.emit("FLOOR[\(name)] 実機相当の品質で 0.40 未満 \(below)/\(faces.count)")
            for floor: Float in [0.40, 0.10] {
                var config = Self.tuning.agglomeration
                config.inclusionFloor = floor
                let result = Self.agglomerative(faces, config: config)
                let unassigned = faces.filter { $0.truth != nil && (result[$0.id] ?? -1) < 0 }.count
                Self.emit(Self.line(String(format: "FLOOR[%@] 平均連結に入れる線 %.2f（入らず %d）", name, floor, unassigned),
                                    Self.score(result, faces), violations: Self.samePhotoViolations(result, faces)))
            }
        }
    }
}
