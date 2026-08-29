import Foundation
import PerceptionCore
import SwiftData

// MARK: - 判定の内訳レポート（Developer Options・ADR-135）

/// 焦点にした人物 1 人ぶんの状態。
public struct PersonDecisionFocus: Sendable, Equatable {
    public let clusterID: Int
    public let name: String?
    /// 重心に寄与しているメンバー数（サイズ適応マージンの入力）。
    public let centroidCount: Int
    /// 写真の数（表示上の「枚数」）。
    public let photoCount: Int
    /// アンカー（確認顔）の数。0 なら**再クラスタで動く可能性がある**（ADR-130/132）。
    public let anchorCount: Int
    public let hasCover: Bool
    public let isGrouped: Bool
    /// 再クラスタの「種」になるか（名前 or アンカー or 束ね）。false＝毎回ばらされる側。
    public var isSeed: Bool { (name?.isEmpty == false) || anchorCount > 0 || isGrouped }
}

/// 近傍 1 人ぶんの判定。
public struct PersonDecisionRow: Sendable, Identifiable, Equatable {
    public let clusterID: Int
    public let name: String?
    public let centroidCount: Int
    public let photoCount: Int
    public let anchorCount: Int
    /// 焦点人物の重心から見た類似度（相手の重心とアンカーの最大＝`assign` と同じ測り方）。
    public let similarity: Float
    /// この相手に入るために要る類似度（しきい値＋サイズ適応の上乗せ）。
    public let required: Float
    public let verdict: FaceDecisionVerdict
    /// 統合候補の帯（`mergeBandFloor` 以上）に入っているか＝レビューに出る可能性。
    public let inMergeBand: Bool
    public var id: Int { clusterID }
}

public struct PersonDecisionReport: Sendable {
    public let focus: PersonDecisionFocus
    public let settings: FaceDecisionSettings
    public let neighbors: [PersonDecisionRow]
    public let totalPeople: Int
    /// 学習済みの負例（「この人ではない」）の数。
    public let negativeCount: Int
}

extension FaceStore {

    /// 焦点人物と近傍の**判定の内訳**を作る（読み取り専用・Developer Options 用）。
    ///
    /// ⚠️ クラスタごとに引かない（ADR-119）。クラスタ行・アンカー・メンバー refKey を
    /// **それぞれ 1 回**取って組み立てる。人物が 1,000 人でも往復は 3 回。
    func decisionReport(clusterID: Int, limit: Int = 12) -> PersonDecisionReport? {
        let clusters = allClusters()
        guard let focus = clusters.first(where: { $0.clusterID == clusterID }),
              let focusSum = ClipMath.decodeHalf(focus.sum) else { return nil }
        let focusVec = FaceClustering.normalized(focusSum)
        let anchors = anchorsByCluster()
        let refKeysByCluster = memberRefKeysByCluster()
        let negatives = loadNegatives()
        let settings = FaceDecisionSettings(
            threshold: calibratedThreshold(),
            baseThreshold: tuning.clusterThreshold,
            assignMargin: tuning.assignMargin,
            sizeAdaptiveMarginMax: tuning.sizeAdaptiveMarginMax,
            matureCount: FaceClustering.matureCountDefault,
            negativeSameThreshold: tuning.negativeSameThreshold,
            mergeBandFloor: tuning.mergeBandFloor(threshold: calibratedThreshold()))
        let focusPhotos = refKeysByCluster[clusterID] ?? []

        // 類似度は `assign` と同じ測り方（相手の重心とアンカーの最大）。
        var scored: [(cluster: PersonCluster, sim: Float, centroid: [Float])] = []
        for c in clusters where c.clusterID != clusterID {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            let centroid = FaceClustering.normalized(sum)
            var sim = FaceClustering.dot(focusVec, centroid)
            for p in anchors[c.clusterID] ?? [] { sim = max(sim, FaceClustering.dot(focusVec, p)) }
            scored.append((c, sim, centroid))
        }
        scored.sort { $0.sim > $1.sim }

        let best = scored.first?.sim
        let second = scored.count > 1 ? scored[1].sim : nil
        var rows: [PersonDecisionRow] = []
        for entry in scored.prefix(limit) {
            let photos = refKeysByCluster[entry.cluster.clusterID] ?? []
            // マージンゲートの「2 位」は、この候補**以外**の最良（＝候補が 1 位なら 2 位、
            // そうでなければ 1 位）。`assign` が見るのと同じ組み合わせ。
            let runnerUp = (entry.sim == best) ? second : best
            let input = FaceDecisionInputs(
                similarity: entry.sim,
                targetCount: entry.cluster.count,
                runnerUpSimilarity: runnerUp,
                negativeRejected: FaceClustering.negativeRejects(
                    focusVec, centroid: entry.centroid, negatives: negatives,
                    sameThreshold: tuning.negativeSameThreshold),
                sharesPhoto: !focusPhotos.isDisjoint(with: photos),
                nameConflict: FaceStore.namesConflict(focus.name, entry.cluster.name))
            rows.append(PersonDecisionRow(
                clusterID: entry.cluster.clusterID,
                name: entry.cluster.name,
                centroidCount: entry.cluster.count,
                photoCount: photos.count,
                anchorCount: (anchors[entry.cluster.clusterID] ?? []).count,
                similarity: entry.sim,
                required: settings.requiredSimilarity(forCount: entry.cluster.count),
                verdict: FaceDecisionExplain.verdict(input, settings: settings),
                inMergeBand: entry.sim >= settings.mergeBandFloor))
        }
        return PersonDecisionReport(
            focus: PersonDecisionFocus(
                clusterID: clusterID, name: focus.name, centroidCount: focus.count,
                photoCount: focusPhotos.count,
                anchorCount: (anchors[clusterID] ?? []).count,
                hasCover: focus.coverFaceID != nil,
                isGrouped: focus.personGroupID != nil),
            settings: settings, neighbors: rows,
            totalPeople: clusters.count, negativeCount: negatives.count)
    }
}
