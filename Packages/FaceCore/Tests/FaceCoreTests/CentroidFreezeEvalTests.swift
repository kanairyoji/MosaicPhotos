import Foundation
import Testing
@testable import FaceCore

/// **重心の凍結（ADR-210）の計測**（FG-NET / LFW）。
///
/// 凍結は「前夜に測った散らばりが `1 − しきい値` を超えた人物は、日中の追加スキャンで
/// 重心を動かさない」。名前の無い人物は夜の再クラスタで作り直されるので、効くのは
/// **昼の追加スキャンのあいだだけ**。そこで本番の流れをそのまま再現する:
///
/// - 夜: それまでの全顔から作り直す（`rebuildClusters` と同じ順序）→ 散らばりを測る
/// - 昼: その日の新しい顔を `place`（＋フロア未満は第2パス）で逐次に入れる
///
/// を繰り返し、凍結あり／なしで**その日の終わり**の B-Cubed を比べる。場面は 2 つ:
/// 1. 毎晩作り直す（最初に 20%・残りを 1 日 10% ずつ）
/// 2. 何日も作り直さない（最初の晩の散らばりのまま、残り 80% を追加し続ける）
///
/// データは `FaceAccuracyEvalTests` が作る埋め込みキャッシュ（`embeddings-v5.json`）を読む。
/// 無ければスキップ。結果は `<root>/centroid-freeze-latest.txt`。
@Suite("重心の凍結の計測（FG-NET / LFW）", .serialized)
struct CentroidFreezeEvalTests {

    static let root = ProcessInfo.processInfo.environment["FACE_EVAL_DIR"]
        ?? (NSHomeDirectory() + "/DEV/tmp/face-eval")
    static var available: Bool {
        FileManager.default.fileExists(atPath: root + "/fgnet/embeddings-v5.json")
    }
    static let outputPath = root + "/centroid-freeze-latest.txt"

    struct Face {
        let id: String
        let person: String
        let age: Int?
        let embedding: [Float]
        let quality: Float
    }

    struct CacheFile: Decodable {
        let embeddings: [String: [Float]]
        let qualities: [String: Float]?
    }

    static func emit(_ line: String) {
        print(line)
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: outputPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    static func load(_ dataset: String) throws -> [Face] {
        let dir = root + "/" + dataset
        let cache = try JSONDecoder().decode(
            CacheFile.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/embeddings-v5.json")))
        let text = try String(contentsOfFile: dir + "/labels.csv", encoding: .utf8)
        var faces: [Face] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let c = line.split(separator: ",").map(String.init)
            guard c.count >= 2, let e = cache.embeddings[c[0]], !e.isEmpty else { continue }
            faces.append(Face(id: c[0], person: c[1], age: c.count > 2 ? Int(c[2]) : nil,
                              embedding: e, quality: cache.qualities?[c[0]] ?? 1))
        }
        return faces
    }

    // MARK: - 本番の再現

    static let tuning = FaceTuning.arcFace
    static let floor = FaceStore.qualityFloor

    struct Night {
        var clusters: [FaceClustering.Cluster]
        var assignment: [String: Int]
        var frozen: Set<Int>
        var nextID: Int
        var contributed: Set<String>
    }

    /// 夜: 全顔から作り直す（名前・確認なし＝種なし）→ 散らばりを測って凍結を決める。
    static func rebuild(_ faces: [Face], minimumNextID: Int, bar: Float? = nil) -> Night {
        var clustering = FaceClusteringSetup.make(
            threshold: tuning.clusterThreshold, qualityFloor: floor, tuning: tuning,
            seeds: [], minimumNextID: minimumNextID, anchoredClusterIDs: [])
        let pending = faces.sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.id < $1.id }
        var assignment: [String: Int] = [:]
        var contributed = Set<String>()
        for f in pending {
            let p = clustering.place(faceID: f.id, embedding: f.embedding, quality: f.quality)
            assignment[f.id] = p.clusterID
            if p.contributed { contributed.insert(f.id) }
        }
        for f in pending where (assignment[f.id] ?? -1) < 0 && f.quality < floor {
            let cid = clustering.assignMembershipOnly(faceID: f.id, embedding: f.embedding,
                                                      threshold: tuning.secondPassThreshold)
            if cid >= 0 { assignment[f.id] = cid }
        }
        // `recordClusterSpreads` と同じ: 重心を作った顔だけで散らばりを測る。
        var members: [Int: [(embedding: [Float], quality: Float)]] = [:]
        for f in faces where contributed.contains(f.id) {
            if let cid = assignment[f.id], cid >= 0 { members[cid, default: []].append((f.embedding, f.quality)) }
        }
        var frozen = Set<Int>()
        for c in clustering.clusters {
            guard let m = members[c.id] else { continue }
            let spread = FaceClusterHealth.spread(members: m, centroid: c.sum)
            // bar を渡したときは掃引（本番のバー `1 − しきい値` の代わりに使う）。
            let freeze = bar.map { b in m.count >= FaceClusterHealth.minMembersToJudge && (spread ?? 0) > b }
                ?? FaceClusterHealth.shouldFreezeCentroid(spread: spread, members: m.count,
                                                          threshold: tuning.clusterThreshold)
            if freeze {
                frozen.insert(c.id)
            }
        }
        let next = (clustering.clusters.map(\.id).max() ?? minimumNextID - 1) + 1
        return Night(clusters: clustering.clusters, assignment: assignment, frozen: frozen,
                     nextID: max(next, minimumNextID), contributed: contributed)
    }

    /// 昼: 復元したクラスタへ新しい顔を逐次に入れる（`recordScan` と同じ）。
    static func scan(_ newFaces: [Face], night: Night, freeze: Bool)
        -> (assignment: [String: Int], intoFrozen: Int) {
        let seeds = night.clusters.map { c -> FaceClustering.Cluster in
            var s = c
            s.faceIDs = []
            s.centroidFrozen = freeze && night.frozen.contains(c.id)
            return s
        }
        var clustering = FaceClusteringSetup.make(
            threshold: tuning.clusterThreshold, qualityFloor: floor, tuning: tuning,
            seeds: seeds, minimumNextID: night.nextID, anchoredClusterIDs: [])
        var assignment = night.assignment
        var intoFrozen = 0
        for f in newFaces {
            let p = clustering.place(faceID: f.id, embedding: f.embedding, quality: f.quality)
            var cid = p.clusterID
            if cid < 0 && f.quality < floor {
                cid = clustering.assignMembershipOnly(faceID: f.id, embedding: f.embedding)
            }
            assignment[f.id] = cid
            if cid >= 0, freeze, night.frozen.contains(cid) { intoFrozen += 1 }
        }
        return (assignment, intoFrozen)
    }

    static func score(_ assignment: [String: Int], faces: [Face]) -> FaceEvalMetrics.ClusteringScore? {
        var unique = -1_000_000
        var a: [String: Int] = [:]
        for f in faces {
            let cid = assignment[f.id] ?? -1
            if cid >= 0 { a[f.id] = cid } else { a[f.id] = unique; unique -= 1 }
        }
        let truth = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.person) })
        return FaceEvalMetrics.clusteringScore(assignments: a, truth: truth)
    }

    static func line(_ label: String, _ s: FaceEvalMetrics.ClusteringScore?) -> String {
        guard let s else { return "\(label): (なし)" }
        return String(format: "%@: P=%.4f R=%.4f F1=%.4f・最悪の人物の純度 %.3f・純度<0.8 の人物 %d・分裂 %.2f",
                      label, s.bcubedPrecision, s.bcubedRecall, s.bcubedF1,
                      s.worstIdentityPrecision, s.identitiesBelow80Precision, s.clustersPerIdentity)
    }

    // MARK: - 計測

    /// 決定的な並べ替え（固定シードの SplitMix64）。
    static func shuffled(_ faces: [Face], seed: UInt64) -> [Face] {
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var out = faces.sorted { $0.id < $1.id }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            out.swapAt(i, j)
        }
        return out
    }

    @Test("凍結あり／なしで、追加スキャン後の純度を比べる", .enabled(if: available))
    func measure() throws {
        try? FileManager.default.removeItem(atPath: Self.outputPath)
        let fgnet = try Self.load("fgnet")
        let lfw = try Self.load("lfw")
        #expect(fgnet.count > 900)
        #expect(lfw.count > 1000)

        let orders: [(String, [Face])] = [
            // 成長で重心が動く最悪の並び（年齢順＝写真が撮られた順）。
            ("fgnet 年齢順", fgnet.sorted { ($0.age ?? 0, $0.id) < ($1.age ?? 0, $1.id) }),
            ("fgnet 乱順", Self.shuffled(fgnet, seed: 1)),
            ("lfw 乱順", Self.shuffled(lfw, seed: 1)),
        ]
        for (name, ordered) in orders {
            let initial = ordered.count / 5
            let dayCount = 8
            let perDay = (ordered.count - initial + dayCount - 1) / dayCount

            // 場面 1: 毎晩作り直す。
            var sumOn = 0.0, sumOff = 0.0, frozenTotal = 0, intoFrozenTotal = 0
            var worstOn = 1.0, worstOff = 1.0
            var seen = Array(ordered.prefix(initial))
            var nextID = 0
            for day in 0..<dayCount {
                let night = Self.rebuild(seen, minimumNextID: nextID)
                nextID = night.nextID + 10_000
                let start = initial + day * perDay
                guard start < ordered.count else { break }
                let batch = Array(ordered[start..<min(ordered.count, start + perDay)])
                let on = Self.scan(batch, night: night, freeze: true)
                let off = Self.scan(batch, night: night, freeze: false)
                let all = seen + batch
                let sOn = Self.score(on.assignment, faces: all)
                let sOff = Self.score(off.assignment, faces: all)
                sumOn += sOn?.bcubedF1 ?? 0
                sumOff += sOff?.bcubedF1 ?? 0
                worstOn = min(worstOn, sOn?.worstIdentityPrecision ?? 1)
                worstOff = min(worstOff, sOff?.worstIdentityPrecision ?? 1)
                frozenTotal += night.frozen.count
                intoFrozenTotal += on.intoFrozen
                seen = all
            }
            Self.emit(String(format: "FREEZE[%@・毎晩作り直す]: 1 日の終わりの F1 平均 凍結あり %.4f / なし %.4f（差 %+.4f）・最悪の人物の純度 %.3f / %.3f・凍結された人物 のべ %d・凍結された人物に入った新しい顔 %d",
                             name, sumOn / Double(dayCount), sumOff / Double(dayCount),
                             (sumOn - sumOff) / Double(dayCount), worstOn, worstOff,
                             frozenTotal, intoFrozenTotal))

            // 場面 2: 最初の晩のまま作り直さない。
            let night = Self.rebuild(Array(ordered.prefix(initial)), minimumNextID: 0)
            let rest = Array(ordered.dropFirst(initial))
            let on = Self.scan(rest, night: night, freeze: true)
            let off = Self.scan(rest, night: night, freeze: false)
            Self.emit(Self.line("FREEZE[\(name)・作り直さない] 凍結あり（凍結 \(night.frozen.count) 人・入った顔 \(on.intoFrozen)）",
                                Self.score(on.assignment, faces: ordered)))
            Self.emit(Self.line("FREEZE[\(name)・作り直さない] 凍結なし", Self.score(off.assignment, faces: ordered)))

            // 凍結のバーまでどれだけ余裕があるか（散らばりの分布）。
            let spreads = Self.spreads(Self.rebuild(ordered, minimumNextID: 0), faces: ordered)
            if !spreads.isEmpty {
                let s = spreads.sorted()
                Self.emit(String(format: "FREEZE[%@・散らばり]: 8 人以上の人物 %d・中央値 %.3f・最大 %.3f・バー %.2f を超える人物 %d",
                                 name, s.count, s[s.count / 2], s.last!, 1 - Self.tuning.clusterThreshold,
                                 s.filter { $0 > 1 - Self.tuning.clusterThreshold }.count))
            }
        }
    }

    /// 8 人以上の人物の散らばり（全顔で作り直した状態・重心を作った顔だけ＝本番と同じ）。
    static func spreads(_ night: Night, faces: [Face]) -> [Float] {
        var members: [Int: [(embedding: [Float], quality: Float)]] = [:]
        for f in faces where night.contributed.contains(f.id) {
            if let cid = night.assignment[f.id], cid >= 0 { members[cid, default: []].append((f.embedding, f.quality)) }
        }
        return night.clusters.compactMap { c in
            guard let m = members[c.id], m.count >= FaceClusterHealth.minMembersToJudge else { return nil }
            return FaceClusterHealth.spread(members: m, centroid: c.sum)
        }
    }

    @Test("凍結のバーを下げたら効くか（掃引）", .enabled(if: available))
    func sweepBar() throws {
        let fgnet = try Self.load("fgnet")
        let lfw = try Self.load("lfw")
        let orders: [(String, [Face])] = [
            ("fgnet 年齢順", fgnet.sorted { ($0.age ?? 0, $0.id) < ($1.age ?? 0, $1.id) }),
            ("lfw 乱順", Self.shuffled(lfw, seed: 1)),
        ]
        for (name, ordered) in orders {
            let initial = ordered.count / 5
            let rest = Array(ordered.dropFirst(initial))
            let base = Self.rebuild(Array(ordered.prefix(initial)), minimumNextID: 0)
            let off = Self.score(Self.scan(rest, night: base, freeze: false).assignment, faces: ordered)
            Self.emit(Self.line("FREEZE-SWEEP[\(name)・作り直さない] 凍結なし", off))
            for bar: Float in [0.15, 0.20, 0.25, 0.30, 0.35, 0.40] {
                let night = Self.rebuild(Array(ordered.prefix(initial)), minimumNextID: 0, bar: bar)
                let on = Self.scan(rest, night: night, freeze: true)
                Self.emit(Self.line(String(format: "FREEZE-SWEEP[%@・作り直さない] バー %.2f（凍結 %d 人・入った顔 %d）",
                                           name, bar, night.frozen.count, on.intoFrozen),
                                    Self.score(on.assignment, faces: ordered)))
            }
        }
    }
}
