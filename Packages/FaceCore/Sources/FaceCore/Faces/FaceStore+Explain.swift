import CoreGraphics
import Foundation
import MosaicSupport
import PerceptionCore
import SwiftData

// MARK: - 判定の内訳レポート（Developer Options・ADR-135）

/// 焦点にした人物 1 人ぶんの状態。
public struct PersonDecisionFocus: Sendable, Equatable {
    public let clusterID: Int
    public let name: String?
    /// 代表顔（画面の固定ヘッダに出す）。
    public var coverRefKey: String?
    public var coverBoundingBox: CGRect?
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
    /// 代表顔（一覧に出す・「Person 1234」だけでは誰か分からないため）。
    public var coverRefKey: String?
    public var coverBoundingBox: CGRect?
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

/// 焦点人物の中で**重心から外れている顔**（＝混入の候補）。
public struct PersonOutlierFace: Sendable, Identifiable, Equatable {
    public let faceID: String
    public let refKey: String
    public let boundingBox: CGRect
    /// この人物の重心との類似度。低いほど「この人ではない」可能性が高い。
    public let similarity: Float
    public let quality: Double
    /// ユーザーが確認済み（アンカー）か。確認済みなら外れていても本人。
    public let confirmed: Bool
    /// 重心に寄与しているか（第2パスの所属だけの顔は false）。
    public let contributes: Bool
    /// いまの実効しきい値に届いていない＝**今このライブラリなら合流しない**顔。
    public let belowThreshold: Bool
    public var id: String { faceID }
}

/// 間違い候補が出せたか（**出ない理由**を UI で言い分けるため）。
///
/// ⚠️ 空リストには「候補が無い」と「計算していない」の 2 通りがあり、画面から消してしまうと
/// **バグと区別が付かない**（実フィードバック: 「候補がないと出ないのか、バグか分からない」）。
public enum PersonOutlierStatus: Sendable, Equatable {
    /// 計算した（`outliers` がそのまま結果。空なら本当に対象が無い）。
    case computed
    /// この人物に顔が無い。
    case noMembers
    // ※ 旧 `tooManyMembers` は撤去（ADR-177）。人物の大きさで計算を諦めない。
}

public struct PersonDecisionReport: Sendable {
    public let focus: PersonDecisionFocus
    public let settings: FaceDecisionSettings
    public let neighbors: [PersonDecisionRow]
    /// 重心から外れているメンバー（類似度の低い順）＝間違い候補。
    public let outliers: [PersonOutlierFace]
    /// 間違い候補を出せたか（空リストの理由を言い分ける）。
    public let outlierStatus: PersonOutlierStatus
    public let totalPeople: Int
    /// 学習済みの負例（「この人ではない」）の数。
    public let negativeCount: Int
}

extension FaceStore {

    /// 焦点人物と近傍の**判定の内訳**を作る（読み取り専用・Developer Options 用）。
    ///
    /// ⚠️ クラスタごとに引かない（ADR-119）。クラスタ行・アンカー・メンバー refKey を
    /// **それぞれ 1 回**取って組み立てる。人物が 1,000 人でも往復は 3 回。
    /// - Parameters:
    ///   - limit: 近傍を何人まで出すか。
    ///   - outlierLimit: 間違い候補を何枚まで出すか。
    ///     ⚠️ どちらも**呼び出し側が増やせる**（画面の「さらに表示」・ADR-156）。
    ///     最初から全部出すと、写真の多い人物で読み込みが重くなる。
    func decisionReport(clusterID: Int, limit: Int = 12,
                        outlierLimit: Int = 24) -> PersonDecisionReport? {
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
            // 壊れた重心（NaN/Inf）の相手は一覧に出さない（% 表示の Int 変換で trap する）。
            guard sim.isFinite else { continue }
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
        let (outliers, outlierStatus) = outlierFaces(clusterID: clusterID, centroid: focusVec,
                                                     threshold: settings.threshold,
                                                     limit: outlierLimit)

        // 代表顔（焦点＋近傍）。**必要なクラスタの顔だけ**を射影で取る（ADR-119）。
        var needed = Set(rows.map(\.clusterID))
        needed.insert(clusterID)
        let digests = faceDigests(inClusters: needed)
        let coverIDs = Dictionary(clusters.map { ($0.clusterID, $0.coverFaceID) },
                                  uniquingKeysWith: { first, _ in first })
        func cover(_ id: Int) -> (String, CGRect)? {
            guard let members = digests[id], !members.isEmpty else { return nil }
            let pick = coverIDs[id].flatMap { fid in members.first { $0.faceID == fid } }
                ?? members.max { $0.coverScore < $1.coverScore }
            return pick.map { ($0.refKey, $0.box) }
        }
        rows = rows.map { row in
            var row = row
            if let c = cover(row.clusterID) { row.coverRefKey = c.0; row.coverBoundingBox = c.1 }
            return row
        }
        let focusCover = cover(clusterID)
        return PersonDecisionReport(
            focus: PersonDecisionFocus(
                clusterID: clusterID, name: focus.name,
                coverRefKey: focusCover?.0, coverBoundingBox: focusCover?.1,
                centroidCount: focus.count,
                photoCount: focusPhotos.count,
                anchorCount: (anchors[clusterID] ?? []).count,
                hasCover: focus.coverFaceID != nil,
                isGrouped: focus.personGroupID != nil),
            settings: settings, neighbors: rows,
            outliers: outliers, outlierStatus: outlierStatus,
            totalPeople: clusters.count, negativeCount: negatives.count)
    }
}

extension FaceStore {

    /// この人物の中で**重心から外れている顔**を、類似度の低い順に返す（間違い候補）。
    ///
    /// ⚠️ 近傍（他人との距離）だけでは「この人物の中に紛れ込んだ顔」は見つからない。
    /// 混入は**内側**で起きるので、内側からも見る（実フィードバック）。
    /// 確認済み（アンカー）の顔も外れることはある——ユーザーが本人と言っている以上、
    /// 候補には出すが印を付けて区別する。
    func outlierFaces(clusterID: Int, centroid: [Float], threshold: Float,
                      limit: Int = 24, pageSize: Int = 500)
        -> (faces: [PersonOutlierFace], status: PersonOutlierStatus) {
        // ⚠️ **人物の大きさで諦めない**（実フィードバック「顔が N 枚あり、未確認と出る」）。
        // 以前は 8,000 顔で打ち切っていた——`faces(inCluster:)` が埋め込み（1KB/顔）ごと
        // 全件を materialize するので、大きな人物ではメモリが跳ねたため。
        // 埋め込み自体は採点に要るので射影では省けない。代わりに**ページで読み**、
        // 手元には「似ている度の低い上位 `limit` 件」だけを残す（有界）。
        // 見つけたいのは**混入**で、それはいちばん大きな人物でこそ起きる。
        let cid = clusterID
        var scored: [PersonOutlierFace] = []   // 常に limit 件以下・似ている度の昇順
        var broken = 0
        var seen = 0
        var cursor: String?
        while true {
            // faceID 昇順のカーソルで送る（オフセットだと途中の挿入でずれる・ADR-143）。
            //
            // ⚠️ **並びと `>` の比較を同じ順序にする**（`.lexical`）。既定の `SortDescriptor`
            // は数字を意識した順（"…-5" < "…-49"）で並べる一方、`#Predicate` の `>` は
            // 単純な文字列比較なので、両者が食い違うと**ページの継ぎ目で行が飛ぶ**
            // （160 顔のうち 100 顔しか読めなかった。規模テストの変異検証で発覚）。
            var d: FetchDescriptor<DetectedFace>
            if let cursor {
                d = FetchDescriptor<DetectedFace>(
                    predicate: #Predicate { $0.clusterID == cid && $0.faceID > cursor },
                    sortBy: [SortDescriptor(\.faceID, comparator: .lexical)])
            } else {
                d = FetchDescriptor<DetectedFace>(
                    predicate: #Predicate { $0.clusterID == cid },
                    sortBy: [SortDescriptor(\.faceID, comparator: .lexical)])
            }
            d.fetchLimit = pageSize
            let page = (countedFetchOptional(d)) ?? []
            guard !page.isEmpty else { break }
            for f in page {
                seen += 1
                guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
                let sim = FaceClustering.dot(centroid, FaceClustering.normalized(vec))
                // 壊れた埋め込み（NaN/Inf）は表示側へ渡さない（% 表示の Int 変換で trap する）。
                guard sim.isFinite else { broken += 1; continue }
                // 上位 limit 件に入らないものは捨てる（有界）。
                if scored.count >= limit, let worst = scored.last, sim >= worst.similarity { continue }
                let face = PersonOutlierFace(
                    faceID: f.faceID, refKey: f.refKey,
                    boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh),
                    similarity: sim, quality: f.quality,
                    confirmed: f.confirmedAt != nil,
                    contributes: FaceStore.contributesToCentroid(f),
                    belowThreshold: sim < threshold)
                let at = scored.firstIndex { $0.similarity > sim } ?? scored.count
                scored.insert(face, at: at)
                if scored.count > limit { scored.removeLast() }
            }
            if page.count < pageSize { break }
            cursor = page.last?.faceID
        }
        guard seen > 0 else { return ([], .noMembers) }
        if broken > 0 {
            Diagnostics.mark("faces: outliers — 壊れた類似度 \(broken) 件を除外（cluster=\(clusterID)）")
        }
        return (scored, .computed)
    }
}
