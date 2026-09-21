import Foundation
import MosaicSupport
import PerceptionCore
import SwiftData

/// 再クラスタの補助: **重心の整合検査**・**散らばりの記録**（ADR-210）と、根拠別の成績。
/// 判断そのものは純ロジック側にあり、ここは永続層との受け渡しと診断ログだけを持つ。
///
/// ⚠️ 連写（ADR-211）・服装（ADR-212）による連結はここにあったが、PIPA の計測で
/// 効果が無い（繋いだ顔の正解率 0%・B-Cubed F1 が下がる）と分かり撤回した。
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

    // MARK: - 根拠別の成績（ADR-212）

    /// **どの根拠で入った顔を、ユーザーが何割外したか**（本割り当て／第2パス／吸収）。
    ///
    /// 第2パス（ADR-66）の正解率はデータセットで 88〜92% と測れているが、実機の
    /// ユーザーがどれだけ外したかはここでしか分からない。
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
