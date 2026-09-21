import Foundation
import MosaicSupport
import PerceptionCore
import SwiftData

/// 再クラスタの補助: **重心の整合検査**（ADR-210）と、**埋め込み以外の証拠による連結**
/// （連写＝ADR-211 / 服装＝ADR-212）。判断そのものは純ロジック側にあり、ここは
/// 永続層との受け渡しと診断ログだけを持つ。
extension FaceStore {

    // MARK: - 重心の整合検査（ADR-210）

    /// 記録された `sum`/`count` が実体と食い違っていないかを突き合わせ、診断ログへ出す。
    /// **直しには行かない**——このあと再クラスタが作り直すので、ここは「見つけて言う」だけ。
    @discardableResult
    func centroidDriftFindings(existing: [PersonCluster],
                               facesByCluster: [Int: [DetectedFace]]) -> [FaceCentroidAudit.Finding] {
        var embeddings: [String: [Float]] = [:]
        let states = existing.compactMap { c -> FaceCentroidAudit.ClusterState? in
            guard let sum = ClipMath.decodeHalf(c.sum) else { return nil }
            let members = (facesByCluster[c.clusterID] ?? []).map { f in
                FaceCentroidAudit.Member(faceID: f.faceID, quality: Float(f.quality),
                                         contributes: Self.contributesToCentroid(f))
            }
            for f in facesByCluster[c.clusterID] ?? [] where Self.contributesToCentroid(f) {
                // ⚠️ 寄与している顔だけ復号する。全顔だと 86k × 512 次元（ADR-119/122）。
                embeddings[f.faceID] = ClipMath.decodeHalf(f.embedding)
            }
            return FaceCentroidAudit.ClusterState(clusterID: c.clusterID, storedSum: sum,
                                                  storedCount: c.count, members: members)
        }
        return FaceCentroidAudit.check(clusters: states, embedding: { embeddings[$0] })
    }

    func reportCentroidDrift(existing: [PersonCluster], facesByCluster: [Int: [DetectedFace]]) {
        let findings = centroidDriftFindings(existing: existing, facesByCluster: facesByCluster)
        guard !findings.isEmpty else { return }
        Diagnostics.mark("faces: centroid drift — \(FaceCentroidAudit.summary(findings))")
    }

    // MARK: - 連写の連結（ADR-211）

    /// 連写の同じ位置に写っている顔を、既に人物が決まっている顔へ繋ぐ（所属だけ）。
    /// - Returns: 繋いだ数と、証拠が割れて見送った数。
    func linkByBurst(_ allFaces: [DetectedFace],
                     faceByID: [String: DetectedFace],
                     currentCluster: (DetectedFace) -> Int,
                     contributed: Set<String>,
                     negatives: [FaceClustering.NegativePair],
                     centroidByCluster: [Int: [Float]],
                     newAssignment: inout [String: Int],
                     usedByPhoto: inout [String: Set<Int>],
                     linkSource: inout [String: FaceLinkSource]) -> (linked: Int, conflicts: Int) {
        guard FaceLinkSettingsKeys.isEnabled(FaceLinkSettingsKeys.burstLinking) else {
            return (0, 0)
        }
        // ⚠️ 埋め込みは**一切要らない**（位置と時刻だけで決まる）。ここで復号しないことで、
        // 全顔を対象にしても常駐メモリは増えない。
        let faces = allFaces.map { f in
            TemporalLinking.Face(
                faceID: f.faceID, refKey: f.refKey, captureDate: f.captureDate,
                box: TemporalLinking.Box(x: f.bx, y: f.by, width: f.bw, height: f.bh),
                clusterID: currentCluster(f), contributes: contributed.contains(f.faceID))
        }
        let plan = TemporalLinking.plan(faces: faces) { faceID, clusterID in
            Self.isNegativeBlocked(face: faceByID[faceID], clusterID: clusterID,
                                   negatives: negatives, centroidByCluster: centroidByCluster,
                                   sameThreshold: self.tuning.negativeSameThreshold)
        }
        var linked = 0
        for link in plan.links {
            // 同一写真 cannot-link は純ロジック側でも見ているが、**こちら側の占有表**にも
            // 反映してから確かめる（種で留めた顔はここにしか出てこない）。
            guard let face = faceByID[link.faceID] else { continue }
            guard !(usedByPhoto[face.refKey]?.contains(link.clusterID) ?? false) else { continue }
            newAssignment[link.faceID] = link.clusterID
            usedByPhoto[face.refKey, default: []].insert(link.clusterID)
            linkSource[link.faceID] = .temporal
            linked += 1
        }
        Diagnostics.mark("faces: burst link — 繋いだ \(linked) / トラック \(plan.tracks.count) "
                         + "/ 証拠が割れた \(plan.conflicts)")
        return (linked, plan.conflicts)
    }

    // MARK: - 服装の連結（ADR-212）

    /// 1 つの場面で一度に復号してよい顔の数の上限。
    /// ⚠️ 上限が無いと、長い撮影会 1 回で数千顔ぶんの埋め込みを同時に持つことになる。
    static let torsoSessionFaceLimit = 2_000

    /// 同じ場面で服装が一致する顔を、その場面で顔が確立している人物へ繋ぐ（所属だけ）。
    func linkByTorso(_ allFaces: [DetectedFace],
                     faceByID: [String: DetectedFace],
                     currentCluster: (DetectedFace) -> Int,
                     contributed: Set<String>,
                     negatives: [FaceClustering.NegativePair],
                     centroidByCluster: [Int: [Float]],
                     newAssignment: inout [String: Int],
                     usedByPhoto: inout [String: Set<Int>],
                     linkSource: inout [String: FaceLinkSource]) -> (linked: Int, probe: [Float: Int]) {
        guard FaceLinkSettingsKeys.isEnabled(FaceLinkSettingsKeys.torsoLinking) else {
            return (0, [:])
        }
        // 胴体を持つ顔だけが対象。⚠️ ここで**軽い行だけ**を並べ、埋め込みは場面ごとに復号する。
        let rows = allFaces.filter { $0.torsoEmbedding != nil && $0.captureDate != nil }
            .sorted {
                let da = $0.captureDate ?? .distantPast, db = $1.captureDate ?? .distantPast
                if da != db { return da < db }
                if $0.refKey != $1.refKey { return $0.refKey < $1.refKey }
                return $0.faceID < $1.faceID
            }
        guard rows.count >= 2 else { return (0, [:]) }
        let boundaries = TorsoLinking.sessionBoundaries(dates: rows.map { $0.captureDate ?? .distantPast })

        var linked = 0
        var probe: [Float: Int] = [:]
        var skippedSessions = 0
        for range in boundaries {
            guard range.count >= 2 else { continue }
            guard range.count <= Self.torsoSessionFaceLimit else { skippedSessions += 1; continue }
            var sessionFaces: [TorsoLinking.Face] = []
            sessionFaces.reserveCapacity(range.count)
            for index in range {
                let f = rows[index]
                guard let embedding = ClipMath.decodeHalf(f.embedding),
                      let torsoData = f.torsoEmbedding,
                      let torso = ClipMath.decodeHalf(torsoData) else { continue }
                sessionFaces.append(TorsoLinking.Face(
                    faceID: f.faceID, refKey: f.refKey, captureDate: f.captureDate,
                    clusterID: currentCluster(f), contributes: contributed.contains(f.faceID),
                    embedding: embedding, torso: torso))
            }
            // 場面 1 つぶんで判断して、埋め込みはここで捨てる。
            let plan = TorsoLinking.plan(
                faces: sessionFaces, sessionGap: .greatestFiniteMagnitude,
                faceFloor: tuning.torsoFaceFloor,
                isBlocked: { faceID, clusterID in
                    Self.isNegativeBlocked(face: faceByID[faceID], clusterID: clusterID,
                                           negatives: negatives,
                                           centroidByCluster: centroidByCluster,
                                           sameThreshold: self.tuning.negativeSameThreshold)
                })
            for (bar, count) in plan.probe { probe[bar, default: 0] += count }
            for link in plan.links {
                guard let face = faceByID[link.faceID] else { continue }
                guard !(usedByPhoto[face.refKey]?.contains(link.clusterID) ?? false) else { continue }
                newAssignment[link.faceID] = link.clusterID
                usedByPhoto[face.refKey, default: []].insert(link.clusterID)
                linkSource[link.faceID] = .torso
                linked += 1
            }
        }
        // ⚠️ **バーを動かす判断の材料をログに出す**（ADR-162 と同じ）。顔のデータセットには
        // 服装が無いので、決めるのは実機のこの分布と、根拠別の付け替え率しかない。
        let distribution = TorsoLinking.probeBars
            .map { "\($0)=\(probe[$0] ?? 0)" }.joined(separator: " ")
        Diagnostics.mark("faces: torso link — 繋いだ \(linked) / 対象 \(rows.count) "
                         + "/ 場面 \(boundaries.count)（大きすぎて見送り \(skippedSessions)）"
                         + " bar=\(TorsoLinking.defaultTorsoBar) | バー別に繋がる数 \(distribution)")
        return (linked, probe)
    }

    // MARK: - 共通

    /// 負例（ユーザーが「この人ではない」と言った記録）がこの連結を拒否するか。
    ///
    /// ⚠️ **相対で判定する**（ADR-140）。絶対値だけで見ると、本人の顔を 1 枚外しただけで
    /// 本人の他の顔も全部その負例に一致してしまう（実測 12 枚 → 3 枚）。
    /// ⚠️ 判定の式は `FaceClustering.place` の負例判定と**同じ**にする。ここだけ緩いと、
    /// 本割り当てが拒否した組み合わせを、あとから連結が通してしまう。
    static func isNegativeBlocked(face: DetectedFace?, clusterID: Int,
                                  negatives: [FaceClustering.NegativePair],
                                  centroidByCluster: [Int: [Float]],
                                  sameThreshold: Float) -> Bool {
        guard !negatives.isEmpty, let face,
              let centroid = centroidByCluster[clusterID],
              let vector = ClipMath.decodeHalf(face.embedding) else { return false }
        let v = FaceClustering.normalized(vector)
        guard let matched = FaceClustering.firstNegativeMatch(
            v, centroid: centroid, negatives: negatives,
            sameThreshold: sameThreshold) else { return false }
        let toRejected = FaceClustering.dot(v, matched.faceCentroid)
        let toCluster = FaceClustering.dot(v, centroid)
        return toRejected >= FaceClustering.negativeDuplicateThreshold
            || toRejected > toCluster + FaceClustering.negativeMargin
    }

    // MARK: - 根拠別の成績（ADR-212）

    /// **どの根拠で入った顔を、ユーザーが何割外したか**。
    ///
    /// ⚠️ これが連写・服装の連結を判断する唯一の物差しになる。顔のデータセット
    /// （FG-NET / LFW）は顔のクロップだけで、連写も場面も服装も持たないので、
    /// 「良くなったか」をそこで測ることはできない。バーを動かすのはこの数字が出てから
    /// ——断片吸収のバーを実機の分布で決めた ADR-162 と同じ手順を踏む。
    func linkSourceReport() -> (linked: [String: Int], corrected: [String: Int]) {
        var linked: [String: Int] = [:]
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID >= 0 })
        d.propertiesToFetch = [\.linkSource, \.clusterID]
        for face in (countedFetchOptional(d)) ?? [] {
            linked[face.linkSource ?? FaceLinkSource.face.rawValue, default: 0] += 1
        }
        var corrected: [String: Int] = [:]
        var c = FetchDescriptor<FaceCorrection>(predicate: #Predicate { $0.kind == "reassign" })
        c.propertiesToFetch = [\.linkSource, \.kind]
        for row in (countedFetchOptional(c)) ?? [] {
            guard let source = row.linkSource else { continue }   // 列より前の記録は数えない
            corrected[source, default: 0] += 1
        }
        return (linked, corrected)
    }

    /// 上の成績を診断ログへ 1 行で出す。
    func reportLinkSources() {
        let report = linkSourceReport()
        guard !report.linked.isEmpty else { return }
        let rows = FaceLinkSource.allCases.compactMap { source -> String? in
            let linked = report.linked[source.rawValue] ?? 0
            guard linked > 0 else { return nil }
            let corrected = report.corrected[source.rawValue] ?? 0
            return "\(source.rawValue)=\(linked)(外した \(corrected))"
        }.joined(separator: " ")
        Diagnostics.mark("faces: link sources — \(rows)")
    }

    // MARK: - 散らばりの記録（ADR-210）

    /// 最終的な所属から、各人物の**散らばり**（`FaceClusterHealth.spread`）を測って記録する。
    /// 次のスキャンはこの値を見て、散らばりすぎた人物の重心を凍結する。
    ///
    /// - Parameter contributed: 重心を作った顔の faceID（散らばりも**この顔だけ**で測る——
    ///   membership だけの顔は定義上いつも遠いので、混ぜると全員が「散らばっている」になる）。
    func recordClusterSpreads(faces: [DetectedFace], contributed: Set<String>) {
        var membersByCluster: [Int: [(embedding: [Float], quality: Float)]] = [:]
        for f in faces where f.clusterID >= 0 && contributed.contains(f.faceID) {
            guard let vector = ClipMath.decodeHalf(f.embedding) else { continue }
            membersByCluster[f.clusterID, default: []].append((vector, Float(f.quality)))
        }
        var frozen = 0
        let threshold = calibratedThreshold()
        for c in allClusters() {
            guard let members = membersByCluster[c.clusterID], !members.isEmpty,
                  let sum = ClipMath.decodeHalf(c.sum) else { c.spread = nil; continue }
            let spread = FaceClusterHealth.spread(members: members, centroid: sum)
            c.spread = spread.map { Double($0) }
            if FaceClusterHealth.shouldFreezeCentroid(spread: spread, members: members.count,
                                                      threshold: threshold) { frozen += 1 }
        }
        if frozen > 0 {
            Diagnostics.mark("faces: centroid frozen — \(frozen) 人（ばらつきがしきい値の裏側）")
        }
    }
}
