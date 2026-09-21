import AutoAlbumCore
import ImageIO
import MobileCLIPKit
import XCTest

/// **連写・服装の連結（ADR-211/212）の計測ハーネス**（PIPA）。
///
/// 顔のデータセット（FG-NET / LFW）は顔のクロップだけで、連写も場面も服装も無い。
/// PIPA は Flickr の個人アルバムに頭の矩形・人物 ID・撮影時刻が付いており、
/// 本物の連写（同じアルバムで 3 秒以内）が数千組ある＝ここでだけ測れる。
///
/// 本番の再クラスタ（`FaceStore.rebuildClusters`）と**同じ順序**を再現する:
/// 品質降順の割り当て → 第2パス（所属だけ）→ 連写 → 服装。人物の名前・確認は無い
/// （新しいライブラリの初回と同じ）。そのうえで
/// - 繋いだ顔が**正しい人物**（その人物の重心を作った顔の多数派）に入ったか
/// - 全体の B-Cubed（連結なし／連写だけ／服装だけ／両方）
/// - 対照: 服装を使わず、顔のしきい値だけを服装の最低線まで下げた場合
///   （服装が効いているのか、低いしきい値が効いているのかを分ける）
/// を出す。
///
/// 使い方:
/// 1. `python3 scripts/fetch_pipa_eval.py`（~/DEV/tmp/face-eval-pipa/ に画像と注釈）
/// 2. xcodebuild test -project MosaicPhotos.xcodeproj -scheme MosaicPhotos \
///      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///      -only-testing:MosaicPhotosTests/PIPALinkingEvalTests
/// 3. 結果は `<root>/pipa-linking-latest.txt`（埋め込みは `<root>/cache-*` にキャッシュ）
final class PIPALinkingEvalTests: XCTestCase {

    struct Head {
        let x: Double, y: Double, w: Double, h: Double   // 画素・原点左上
        let identity: String
    }

    struct Photo {
        let id: String
        let album: String
        let date: Date
        var heads: [Head]
    }

    /// 1 顔ぶん（キャッシュの単位でもある）。
    struct CachedFace: Codable {
        let box: [Double]          // Vision 正規化（原点左下）x, y, w, h
        let embedding: Data        // Float16
        let quality: Float
        let torso: Data?           // Float16
    }

    struct CachedPhoto: Codable {
        let width: Int
        let height: Int
        let faces: [CachedFace]
    }

    struct Face {
        let id: String
        let photo: String
        let album: String
        let date: Date
        let box: TemporalLinking.Box
        let embedding: [Float]
        let quality: Float
        let torso: [Float]?
        var truth: String?
    }

    static let root = ProcessInfo.processInfo.environment["PIPA_EVAL_DIR"]
        ?? "/Users/kanai/DEV/tmp/face-eval-pipa"
    static let outputPath = root + "/pipa-linking-latest.txt"

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

    func testLinkingOnPIPA() async throws {
        let annotations = Self.root + "/annotations.csv"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: annotations),
                          "PIPA なし（python3 scripts/fetch_pipa_eval.py）")
        try XCTSkipUnless(FaceModel.modelBundled, "顔モデル未同梱")
        try? FileManager.default.removeItem(atPath: Self.outputPath)
        Self.emit("PIPA: model=\(Self.modelID) "
                  + "clip=\(MobileCLIP.modelsBundled) torsoEnabled=\(FacePerceptionAdapter.torsoEnabled)")

        let photos = try Self.loadAnnotations(annotations)
        let faces = try await extract(photos: photos)
        let truthed = faces.filter { $0.truth != nil }.count
        let withTorso = faces.filter { $0.torso != nil }.count
        let belowFloor = faces.filter { $0.quality < Self.qualityFloor }.count
        Self.emit("PIPA: 写真 \(photos.count) 枚・顔 \(faces.count)（正解と対応 \(truthed)・"
                  + "胴体あり \(withTorso)・品質フロア未満 \(belowFloor)）")
        XCTAssertGreaterThan(truthed, 100, "正解と対応した顔が少なすぎる（座標系の取り違え？）")

        let tuning = FaceTuning.arcFace
        let base = Self.baseAssignment(faces, tuning: tuning)
        Self.report(label: "第2パス（参考）", faces: faces, links: base.secondPass, state: base)

        // --- 連結なし／連写／服装／両方（本番の既定値） ---
        let truth = Dictionary(uniqueKeysWithValues: faces.compactMap { f in f.truth.map { (f.id, $0) } })
        Self.emitScore("連結なし", base.assignment, truth)

        let burst = Self.burstLinks(faces, state: base)
        Self.report(label: "連写 gap=3s IoU=0.5", faces: faces, links: burst.links, state: base)
        Self.emit("PIPA[連写]: トラック \(burst.tracks)・証拠が割れた \(burst.conflicts)")
        var afterBurst = base
        Self.apply(burst.links, faces: faces, to: &afterBurst)
        Self.emitScore("連写だけ", afterBurst.assignment, truth)

        let torsoOnly = Self.torsoLinks(faces, state: base, bar: TorsoLinking.defaultTorsoBar,
                                        faceFloor: tuning.torsoFaceFloor)
        Self.report(label: "服装だけ bar=0.90", faces: faces, links: torsoOnly, state: base)
        var afterTorso = base
        Self.apply(torsoOnly, faces: faces, to: &afterTorso)
        Self.emitScore("服装だけ", afterTorso.assignment, truth)

        let torsoAfterBurst = Self.torsoLinks(faces, state: afterBurst,
                                              bar: TorsoLinking.defaultTorsoBar,
                                              faceFloor: tuning.torsoFaceFloor)
        Self.report(label: "服装（連写のあと）", faces: faces, links: torsoAfterBurst, state: afterBurst)
        var both = afterBurst
        Self.apply(torsoAfterBurst, faces: faces, to: &both)
        Self.emitScore("両方（本番）", both.assignment, truth)

        // --- 掃引 ---
        for gap in [1.0, 3.0, 10.0] {
            for iou in [0.3, 0.5, 0.7] {
                let plan = Self.burstLinks(faces, state: base, maxGap: gap, minIoU: iou)
                Self.report(label: "連写 gap=\(gap)s IoU=\(iou)", faces: faces, links: plan.links,
                            state: base)
            }
        }
        for bar: Float in [0.70, 0.75, 0.80, 0.85, 0.90, 0.95] {
            let links = Self.torsoLinks(faces, state: base, bar: bar, faceFloor: tuning.torsoFaceFloor)
            Self.report(label: "服装 bar=\(bar)", faces: faces, links: links, state: base)
        }

        // --- 対照: 服装を見ずに、顔のしきい値だけを服装の最低線まで下げる ---
        // 服装の連結は「顔 ≥ torsoFaceFloor（0.30）かつ 胴体 ≥ バー」。後半を外した版と比べれば、
        // 胴体が精度に寄与しているのか、単に低いしきい値で拾っているだけなのかが分かる。
        for floor: Float in [tuning.torsoFaceFloor, 0.35] {
            let links = Self.faceOnlyControl(faces, state: base, threshold: floor)
            Self.report(label: "対照 顔だけ≥\(floor)（同じ場面に限らない）", faces: faces,
                        links: links, state: base)
        }
        Self.torsoSeparability(faces)
    }

    // MARK: - 本番の再クラスタの再現

    static let qualityFloor: Float = 0.40   // FaceStore.qualityFloor と同値

    /// 同梱顔モデルの ID（face_config.json の `model`）。キャッシュ名に入れて、モデル更新で無効化する。
    static var modelID: String {
        guard let url = Bundle.main.url(forResource: "face_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = json["model"] as? String else { return "unknown" }
        return model
    }

    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }

    struct State {
        var assignment: [String: Int]
        var contributed: Set<String>
        var usedByPhoto: [String: Set<Int>]
        var secondPass: [(faceID: String, clusterID: Int)]
        var clustering: FaceClustering
    }

    static func baseAssignment(_ faces: [Face], tuning: FaceTuning) -> State {
        var clustering = FaceClusteringSetup.make(
            threshold: tuning.clusterThreshold, qualityFloor: qualityFloor, tuning: tuning,
            seeds: [], minimumNextID: 0, anchoredClusterIDs: [])
        let pending = faces.sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.id < $1.id }
        var state = State(assignment: [:], contributed: [], usedByPhoto: [:], secondPass: [],
                          clustering: clustering)
        for f in pending {
            let placement = clustering.place(faceID: f.id, embedding: f.embedding, quality: f.quality,
                                             negatives: [],
                                             excludedClusterIDs: state.usedByPhoto[f.photo] ?? [])
            state.assignment[f.id] = placement.clusterID
            if placement.clusterID >= 0 { state.usedByPhoto[f.photo, default: []].insert(placement.clusterID) }
            if placement.contributed { state.contributed.insert(f.id) }
        }
        for f in pending where (state.assignment[f.id] ?? -1) < 0 && f.quality < qualityFloor {
            let cid = clustering.assignMembershipOnly(
                faceID: f.id, embedding: f.embedding,
                excludedClusterIDs: state.usedByPhoto[f.photo] ?? [],
                threshold: tuning.secondPassThreshold)
            if cid >= 0 {
                state.assignment[f.id] = cid
                state.usedByPhoto[f.photo, default: []].insert(cid)
                state.secondPass.append((f.id, cid))
            }
        }
        state.clustering = clustering
        return state
    }

    static func burstLinks(_ faces: [Face], state: State,
                           maxGap: TimeInterval = TemporalLinking.defaultMaxGap,
                           minIoU: Double = TemporalLinking.defaultMinIoU)
        -> (links: [(faceID: String, clusterID: Int)], tracks: Int, conflicts: Int) {
        let input = faces.map { f in
            TemporalLinking.Face(faceID: f.id, refKey: f.photo, captureDate: f.date, box: f.box,
                                 clusterID: state.assignment[f.id] ?? -1,
                                 contributes: state.contributed.contains(f.id))
        }
        let plan = TemporalLinking.plan(faces: input, maxGap: maxGap, minIoU: minIoU)
        var used = state.usedByPhoto
        var out: [(String, Int)] = []
        let photoOf = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.photo) })
        for link in plan.links {
            let photo = photoOf[link.faceID]!
            guard !(used[photo]?.contains(link.clusterID) ?? false) else { continue }
            used[photo, default: []].insert(link.clusterID)
            out.append((link.faceID, link.clusterID))
        }
        return (out, plan.tracks.count, plan.conflicts)
    }

    static func torsoLinks(_ faces: [Face], state: State, bar: Float, faceFloor: Float)
        -> [(faceID: String, clusterID: Int)] {
        let rows = faces.filter { $0.torso != nil }
            .sorted { $0.date != $1.date ? $0.date < $1.date
                      : ($0.photo != $1.photo ? $0.photo < $1.photo : $0.id < $1.id) }
        guard rows.count >= 2 else { return [] }
        var used = state.usedByPhoto
        var out: [(String, Int)] = []
        for range in TorsoLinking.sessionBoundaries(dates: rows.map(\.date)) where range.count >= 2 {
            let input = range.map { i -> TorsoLinking.Face in
                let f = rows[i]
                return TorsoLinking.Face(faceID: f.id, refKey: f.photo, captureDate: f.date,
                                         clusterID: state.assignment[f.id] ?? -1,
                                         contributes: state.contributed.contains(f.id),
                                         embedding: f.embedding, torso: f.torso)
            }
            let plan = TorsoLinking.plan(faces: input, sessionGap: .greatestFiniteMagnitude,
                                         torsoBar: bar, faceFloor: faceFloor)
            for link in plan.links {
                let photo = rows[range].first { $0.id == link.faceID }!.photo
                guard !(used[photo]?.contains(link.clusterID) ?? false) else { continue }
                used[photo, default: []].insert(link.clusterID)
                out.append((link.faceID, link.clusterID))
            }
        }
        return out
    }

    /// 対照: 未割当の顔を、服装を見ずに最寄り人物へ（しきい値だけ下げた第2パス）。
    static func faceOnlyControl(_ faces: [Face], state: State, threshold: Float)
        -> [(faceID: String, clusterID: Int)] {
        var clustering = state.clustering
        var used = state.usedByPhoto
        var out: [(String, Int)] = []
        for f in faces where (state.assignment[f.id] ?? -1) < 0 {
            let cid = clustering.assignMembershipOnly(
                faceID: f.id, embedding: f.embedding,
                excludedClusterIDs: used[f.photo] ?? [], threshold: threshold)
            if cid >= 0 {
                used[f.photo, default: []].insert(cid)
                out.append((f.id, cid))
            }
        }
        return out
    }

    static func apply(_ links: [(faceID: String, clusterID: Int)], faces: [Face], to state: inout State) {
        let photoOf = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.photo) })
        for link in links {
            state.assignment[link.faceID] = link.clusterID
            state.usedByPhoto[photoOf[link.faceID]!, default: []].insert(link.clusterID)
        }
    }

    // MARK: - 採点

    /// 各人物の「本人」＝重心を作った顔の正解の多数派。
    static func majority(faces: [Face], state: State) -> [Int: String] {
        let truth = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.truth) })
        var votes: [Int: [String: Int]] = [:]
        for (faceID, cid) in state.assignment where cid >= 0 && state.contributed.contains(faceID) {
            guard let t = truth[faceID] ?? nil else { continue }
            votes[cid, default: [:]][t, default: 0] += 1
        }
        return votes.compactMapValues { $0.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key }
    }

    static func report(label: String, faces: [Face], links: [(faceID: String, clusterID: Int)],
                       state: State) {
        let owner = majority(faces: faces, state: state)
        let truth = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0.truth) })
        var correct = 0, wrong = 0, faceUnknown = 0, ownerUnknown = 0
        for link in links {
            guard let t = truth[link.faceID] ?? nil else { faceUnknown += 1; continue }
            guard let o = owner[link.clusterID] else { ownerUnknown += 1; continue }
            if t == o { correct += 1 } else { wrong += 1 }
        }
        let judged = correct + wrong
        let precision = judged > 0 ? Double(correct) / Double(judged) * 100 : .nan
        emit(String(format: "PIPA[%@]: 繋いだ %d（正 %d・誤 %d・正解率 %.1f%%｜顔の正解なし %d・人物の正解なし %d）",
                    label, links.count, correct, wrong, precision, faceUnknown, ownerUnknown))
    }

    static func emitScore(_ label: String, _ assignment: [String: Int], _ truth: [String: String]) {
        var unique = -1_000_000
        var a: [String: Int] = [:]
        for (id, cid) in assignment {
            if cid >= 0 { a[id] = cid } else { a[id] = unique; unique -= 1 }
        }
        guard let s = FaceEvalMetrics.clusteringScore(assignments: a, truth: truth) else { return }
        let assigned = truth.keys.filter { (assignment[$0] ?? -1) >= 0 }.count
        emit(String(format: "PIPA[%@]: B-Cubed P=%.4f R=%.4f F1=%.4f・人物に入った顔 %d/%d・分裂 %.2f",
                    label, s.bcubedPrecision, s.bcubedRecall, s.bcubedF1, assigned, truth.count,
                    s.clustersPerIdentity))
    }

    /// 胴体の埋め込みが「同じ場面の同じ人」と「同じ場面の別人」を分けられるか（AUC）。
    static func torsoSeparability(_ faces: [Face]) {
        let rows = faces.filter { $0.torso != nil && $0.truth != nil }
        var byAlbum: [String: [Face]] = [:]
        for f in rows { byAlbum[f.album, default: []].append(f) }
        var same: [Float] = [], diff: [Float] = []
        for group in byAlbum.values {
            let normalized = group.map { Self.unit($0.torso!) }
            for i in group.indices {
                for j in (i + 1)..<group.count where group[i].photo != group[j].photo
                    && abs(group[i].date.timeIntervalSince(group[j].date)) <= TorsoLinking.defaultSessionGap {
                    let s = FaceClustering.dot(normalized[i], normalized[j])
                    if group[i].truth == group[j].truth { same.append(s) } else { diff.append(s) }
                }
            }
        }
        guard !same.isEmpty, !diff.isEmpty else {
            emit("PIPA[胴体の分離]: 対が足りない（同 \(same.count)・別 \(diff.count)）")
            return
        }
        let sortedDiff = diff.sorted()
        var wins = 0.0
        for s in same {
            var lo = 0, hi = sortedDiff.count
            while lo < hi { let m = (lo + hi) / 2; if sortedDiff[m] < s { lo = m + 1 } else { hi = m } }
            wins += Double(lo)
        }
        let auc = wins / (Double(same.count) * Double(sortedDiff.count))
        func q(_ v: [Float], _ p: Double) -> Float { let s = v.sorted(); return s[Int(Double(s.count - 1) * p)] }
        emit(String(format: "PIPA[胴体の分離]: 同じ場面・同じ人 %d 対（中央 %.3f・下位10%% %.3f）／別人 %d 対（中央 %.3f・上位10%% %.3f）・AUC %.3f",
                    same.count, q(same, 0.5), q(same, 0.1), diff.count, q(diff, 0.5), q(diff, 0.9), auc))
        for bar: Float in [0.80, 0.85, 0.90, 0.95] {
            let sp = Double(same.filter { $0 >= bar }.count) / Double(same.count) * 100
            let dp = Double(diff.filter { $0 >= bar }.count) / Double(diff.count) * 100
            emit(String(format: "PIPA[胴体の分離]: ≥%.2f に入る割合 同じ人 %.1f%%・別人 %.1f%%", bar, sp, dp))
        }
    }

    // MARK: - データ

    static func loadAnnotations(_ path: String) throws -> [Photo] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var photos: [String: Photo] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let c = line.split(separator: ",").map(String.init)
            guard c.count == 8, let date = parser.date(from: c[2]),
                  let x = Double(c[3]), let y = Double(c[4]), let w = Double(c[5]), let h = Double(c[6])
            else { continue }
            let head = Head(x: x, y: y, w: w, h: h, identity: c[7])
            if photos[c[0]] == nil {
                photos[c[0]] = Photo(id: c[0], album: c[1], date: date, heads: [])
                order.append(c[0])
            }
            photos[c[0]]!.heads.append(head)
        }
        return order.map { photos[$0]! }
    }

    func extract(photos: [Photo]) async throws -> [Face] {
        let version = Self.modelID
        let cacheDir = Self.root + "/cache-\(version)"
        try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        let adapter = FacePerceptionAdapter()
        var faces: [Face] = []
        var processed = 0
        let started = Date()
        for photo in photos {
            let cachePath = "\(cacheDir)/\(photo.id).json"
            var cached: CachedPhoto?
            if let data = FileManager.default.contents(atPath: cachePath) {
                cached = try? JSONDecoder().decode(CachedPhoto.self, from: data)
            }
            if cached == nil {
                let url = URL(fileURLWithPath: "\(Self.root)/images/\(photo.id).jpg")
                guard let cg = autoreleasepool(invoking: { Self.loadCGImage(url, maxPixel: 2048) }) else { continue }
                let signals = await adapter.debugSignals(cg)
                let entry = CachedPhoto(width: cg.width, height: cg.height, faces: signals.map {
                    CachedFace(box: [$0.boundingBox.minX, $0.boundingBox.minY,
                                     $0.boundingBox.width, $0.boundingBox.height],
                               embedding: $0.embedding, quality: $0.quality, torso: $0.torsoEmbedding)
                })
                try JSONEncoder().encode(entry).write(to: URL(fileURLWithPath: cachePath))
                cached = entry
                processed += 1
                if processed % 100 == 0 {
                    Self.emit(String(format: "PIPA: 解析 %d 枚（%.1f 秒/枚）", processed,
                                     Date().timeIntervalSince(started) / Double(processed)))
                }
            }
            guard let entry = cached else { continue }
            var photoFaces: [Face] = []
            for (index, f) in entry.faces.enumerated() {
                guard let embedding = ClipMath.decodeHalf(f.embedding) else { continue }
                photoFaces.append(Face(
                    id: "\(photo.id)#\(index)", photo: photo.id, album: photo.album, date: photo.date,
                    box: .init(x: f.box[0], y: f.box[1], width: f.box[2], height: f.box[3]),
                    embedding: embedding, quality: f.quality,
                    torso: f.torso.flatMap { ClipMath.decodeHalf($0) }, truth: nil))
            }
            Self.matchTruth(&photoFaces, heads: photo.heads, width: Double(entry.width),
                            height: Double(entry.height))
            faces.append(contentsOf: photoFaces)
        }
        return faces
    }

    /// 検出した顔を PIPA の頭の矩形へ対応づける（顔の中心が頭の中にあり、顔の面積の半分以上が
    /// 頭と重なるもの。重なりの大きい順に 1 対 1）。
    static func matchTruth(_ faces: inout [Face], heads: [Head], width: Double, height: Double) {
        var candidates: [(face: Int, head: Int, score: Double)] = []
        for (fi, f) in faces.enumerated() {
            let fx0 = f.box.x * width, fx1 = (f.box.x + f.box.width) * width
            let fy0 = (1 - f.box.y - f.box.height) * height, fy1 = (1 - f.box.y) * height
            let cx = (fx0 + fx1) / 2, cy = (fy0 + fy1) / 2
            let area = (fx1 - fx0) * (fy1 - fy0)
            for (hi, h) in heads.enumerated() {
                guard cx >= h.x, cx <= h.x + h.w, cy >= h.y, cy <= h.y + h.h, area > 0 else { continue }
                let ix = max(0, min(fx1, h.x + h.w) - max(fx0, h.x))
                let iy = max(0, min(fy1, h.y + h.h) - max(fy0, h.y))
                let score = ix * iy / area
                if score >= 0.5 { candidates.append((fi, hi, score)) }
            }
        }
        candidates.sort { $0.score > $1.score }
        var usedFace = Set<Int>(), usedHead = Set<Int>()
        for c in candidates where !usedFace.contains(c.face) && !usedHead.contains(c.head) {
            usedFace.insert(c.face); usedHead.insert(c.head)
            faces[c.face].truth = heads[c.head].identity
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
