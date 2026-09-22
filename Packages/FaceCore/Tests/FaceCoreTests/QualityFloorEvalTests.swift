import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// **昼の線と、名前付き人物の重心の線を、実機相当の品質で測る**（ADR-221）。
///
/// 本物の `FaceStore`（メモリ上）で「最初のスキャン → 夜の作り直し → 名前付け →（昼のスキャン → 夜）× N 日」
/// を回す＝本番と同じ経路。品質は Mac で取った OS の品質と合成した実機相当（ADR-220）。
/// - 昼の線（`dayQualityFloor`）: 昼の逐次割り当てで重心へ入れる顔の線（未満は所属だけ）
/// - 種の線（`seedQualityFloor`）: 名前付き人物の重心を作り直すときに使う顔の線
///
/// 名前付け: 最初の夜のあと、写っている枚数の多い人から最大 20 人について、その人の顔がいちばん
/// 多く入っている人物（多数派がその人のもの）に名前を付ける＝利用者が正しい人物を選んで名前を付けた状態。
/// 結果は `~/DEV/tmp/face-eval/quality-floor-latest.txt`。データが無ければスキップ。
@Suite("昼の線・種の線（実機相当の品質・計測）", .serialized)
struct QualityFloorEvalTests {

    typealias Face = FaceAgglomerationEvalTests.Face
    static let outputPath = FaceAgglomerationEvalTests.root + "/quality-floor-latest.txt"
    static var available: Bool {
        FileManager.default.fileExists(atPath: FaceAgglomerationEvalTests.root + "/fgnet/os-quality.json")
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

    /// 写真ごとの顔（同じ写真の顔は 1 回の `recordScan` で入れる＝同一写真の決まりが効く）。
    struct Photo {
        let refKey: String
        let faces: [Face]
    }

    static func photos(_ faces: [Face], order: [String]) -> [Photo] {
        var byPhoto: [String: [Face]] = [:]
        for f in faces { byPhoto[f.photo, default: []].append(f) }
        return order.compactMap { p in byPhoto[p].map { Photo(refKey: "L-\(p)", faces: $0) } }
    }

    struct Outcome {
        var score: FaceEvalMetrics.ClusteringScore?
        var namedPurity: Double
        var namedRecall: Double
        var named: Int
    }

    /// ストアの今の割り当てを採点する。
    static func measure(_ store: FaceStore, faceIDOf: [String: String],
                        truth: [String: String], namedTruth: [String: String]) async -> Outcome {
        let digests = await store.faceDigestsForTesting()
        let byStoreID = Dictionary(digests.map { ($0.faceID, $0.clusterID) }, uniquingKeysWith: { a, _ in a })
        var assignment: [String: Int] = [:]
        var unique = -1_000_000
        for (id, storeID) in faceIDOf {
            if let cid = byStoreID[storeID], cid >= 0 { assignment[id] = cid } else { assignment[id] = unique; unique -= 1 }
        }
        let score = FaceEvalMetrics.clusteringScore(assignments: assignment, truth: truth)
        // 名前付き人物: 名前（＝正解の人物 ID）が付いた人物の純度と、その人の顔の網羅率。
        let names = await store.namesByClusterForTesting()
        var purity: [Double] = [], recall: [Double] = []
        for (person, _) in namedTruth {
            let clusters = Set(names.filter { $0.value == person }.map(\.key))
            let members = assignment.filter { clusters.contains($0.value) }.map(\.key)
            let mine = truth.filter { $0.value == person }.map(\.key)
            guard !mine.isEmpty else { continue }
            let hits = members.filter { truth[$0] == person }.count
            purity.append(members.isEmpty ? 0 : Double(hits) / Double(members.count))
            recall.append(Double(hits) / Double(mine.count))
        }
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        return Outcome(score: score, namedPurity: mean(purity), namedRecall: mean(recall), named: purity.count)
    }

    /// 1 通りの線で、最初のスキャン → 夜 → 名前付け →（昼 → 夜）× days を回す。
    static func run(_ photos: [Photo], day: Float, seed: Float, days: Int = 4,
                    label: String) async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await store.apply(tuning: .arcFace)
        await store.setQualityFloorsForTesting(day: day, seed: seed)
        var faceIDOf: [String: String] = [:]
        var truth: [String: String] = [:]
        func scan(_ batch: ArraySlice<Photo>) async {
            for photo in batch {
                let signals = photo.faces.map {
                    DetectedFaceSignal(boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                                       embedding: ClipMath.encodeHalf($0.embedding), quality: $0.quality)
                }
                await store.recordScan(refKey: photo.refKey, faces: signals)
                for (i, f) in photo.faces.enumerated() {
                    faceIDOf[f.id] = "\(photo.refKey)#\(i)"
                    if let t = f.truth { truth[f.id] = t }
                }
            }
        }
        let initial = photos.count / 5
        await scan(photos[..<initial])
        _ = await store.rebuildClusters()

        // 名前付け（枚数の多い人から最大 20 人・その人の顔が最も多い人物＝多数派がその人のもの）。
        var counts: [String: Int] = [:]
        for (_, t) in truth { counts[t, default: 0] += 1 }
        let digests = await store.faceDigestsForTesting()
        let clusterOf = Dictionary(digests.map { ($0.faceID, $0.clusterID) }, uniquingKeysWith: { a, _ in a })
        var membersOf: [Int: [String]] = [:]
        for (id, storeID) in faceIDOf { if let c = clusterOf[storeID] { membersOf[c, default: []].append(id) } }
        var namedTruth: [String: String] = [:]
        var usedClusters = Set<Int>()
        for (person, n) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key })
            where n >= 5 && namedTruth.count < 20 {
            var best: (cid: Int, mine: Int)?
            for (cid, members) in membersOf where !usedClusters.contains(cid) {
                let mine = members.filter { truth[$0] == person }.count
                guard mine * 2 > members.count else { continue }   // 多数派がその人のもの
                if let current = best, current.mine > mine || (current.mine == mine && current.cid < cid) { continue }
                best = (cid, mine)
            }
            guard let best else { continue }
            await store.rename(clusterID: best.cid, name: person)
            usedClusters.insert(best.cid)
            namedTruth[person] = person
        }

        let perDay = max(1, (photos.count - initial + days - 1) / days)
        var dayEnd: [Outcome] = [], nightEnd: [Outcome] = []
        for d in 0..<days {
            let start = initial + d * perDay
            guard start < photos.count else { break }
            await scan(photos[start..<min(photos.count, start + perDay)])
            dayEnd.append(await measure(store, faceIDOf: faceIDOf, truth: truth, namedTruth: namedTruth))
            _ = await store.rebuildClusters()
            nightEnd.append(await measure(store, faceIDOf: faceIDOf, truth: truth, namedTruth: namedTruth))
        }
        func line(_ o: [Outcome], _ when: String) -> String {
            guard let last = o.last, let s = last.score else { return "\(label) \(when): (なし)" }
            let meanF1 = o.compactMap { $0.score?.bcubedF1 }.reduce(0, +) / Double(o.count)
            return String(format: "%@ %@: 最終 P=%.4f R=%.4f F1=%.4f（日ごとの F1 平均 %.4f）・純度<0.8 %d・名前付き %d 人の純度 %.3f／網羅 %.3f",
                          label, when, s.bcubedPrecision, s.bcubedRecall, s.bcubedF1, meanF1,
                          s.identitiesBelow80Precision, last.named, last.namedPurity, last.namedRecall)
        }
        emit(line(dayEnd, "昼の終わり"))
        emit(line(nightEnd, "夜の後"))
    }

    /// 振る組み合わせ（昼, 種）。環境変数 `QF_COMBOS="0.2:0.2,0.3:0.2"` で差し替えられる。
    static var combos: [(Float, Float)] {
        if let spec = ProcessInfo.processInfo.environment["QF_COMBOS"] {
            return spec.split(separator: ",").compactMap { pair in
                let v = pair.split(separator: ":").compactMap { Float($0) }
                return v.count == 2 ? (v[0], v[1]) : nil
            }
        }
        return [(0.40, 0.40), (0.20, 0.40), (0.10, 0.40), (0.40, 0.20), (0.40, 0.10), (0.10, 0.10)]
    }

    @Test("昼の線と種の線を振る（実機相当の品質）", .enabled(if: available))
    func sweep() async throws {
        try? FileManager.default.removeItem(atPath: Self.outputPath)
        typealias E = FaceAgglomerationEvalTests
        var sets: [(String, [Face], [String])] = []
        if let fg = E.deviceLike(try E.loadCrops("fgnet"), osQualityPath: E.root + "/fgnet/os-quality.json") {
            sets.append(("fgnet 年齢順", fg, fg.sorted { ($0.age ?? 0, $0.id) < ($1.age ?? 0, $1.id) }.map(\.photo)))
        }
        if let lfw = E.deviceLike(try E.loadCrops("lfw"), osQualityPath: E.root + "/lfw/os-quality.json") {
            sets.append(("lfw 乱順", lfw, CentroidOrder.shuffled(lfw.map(\.photo), seed: 1)))
        }
        if let raw = try E.loadPIPA(), let pipa = E.deviceLike(raw, osQualityPath: E.pipaRoot + "/os-quality.json") {
            var seen = Set<String>()
            let order = pipa.sorted { ($0.date ?? .distantPast, $0.photo) < ($1.date ?? .distantPast, $1.photo) }
                .map(\.photo).filter { seen.insert($0).inserted }
            sets.append(("pipa 撮影日順", pipa, order))
        }
        for (name, faces, order) in sets {
            let photos = Self.photos(faces, order: order)
            for (day, seed) in Self.combos {
                await Self.run(photos, day: day, seed: seed,
                               label: String(format: "QF[%@] 昼 %.2f・種 %.2f", name, day, seed))
            }
        }
    }
}

/// 決定的な並べ替え（固定シードの SplitMix64）。
enum CentroidOrder {
    static func shuffled(_ items: [String], seed: UInt64) -> [String] {
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var out = Array(Set(items)).sorted()
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            out.swapAt(i, Int(next() % UInt64(i + 1)))
        }
        return out
    }
}
