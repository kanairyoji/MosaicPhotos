import Foundation
import MosaicSupport
import PerceptionCore
import SwiftData

// MARK: - 断片の自動吸収（ADR-154）

/// 自動吸収の結果（診断ログと画面に出す）。
public struct FragmentAbsorbResult: Sendable, Equatable {
    /// 吸収した断片クラスタの数。
    public let absorbed: Int
    /// 吸収先になった人物の数。
    public let people: Int
    /// 条件に合わなかった断片の数（近すぎる別人がいる・負例など）。
    public let skipped: Int
    /// **大きさの上限で見送った**クラスタの数（＝上限を上げれば対象になり得る分）。
    /// 上限をどこに置くかを次に決めるための材料（ADR-155）。
    public let skippedTooBig: Int
}

extension FaceStore {

    /// 「断片」とみなす最大の写真枚数。
    ///
    /// ⚠️ **1〜2 枚に限る**（ADR-154）。実フィードバック「1〜2 枚のグループがたくさんあって、
    /// 4,000 枚の人物と同一人物」。枚数が増えるほど「間違えたときに動かす写真」が増え、
    /// 人物どうしの結合（自動化しないと決めた・ADR-153）に近づく。
    static let absorbMaxPhotos = 2
    /// 吸収先として認める最小の写真枚数（＝確立した人物）。
    static let absorbTargetMinPhotos = FaceClustering.matureCountDefault
    /// 2 位との差。**紛らわしければ吸収しない**——兄弟・親子で取り違えないための保険。
    static let absorbMargin: Float = 0.05
    /// 1 回で吸収する上限（夜間処理を有界にする）。
    static let absorbLimitPerRun = 500

    /// 小さな断片を、確立した人物へ機械的に寄せる。
    ///
    /// ⚠️ 人物どうしの結合は**自動化しない**（ADR-153: ユーザー自身が 0.885/0.920 の対を
    /// 「別人」と答えている）。ここが別扱いなのは**失敗の代償が小さい**から:
    /// 断片 1〜2 枚が入っても 4,000 枚の重心は動かず、間違いは 1 枚外せば直る（ADR-133/137）。
    /// 逆に確立した人物どうしを機械が混ぜると、取り返しが付かない（ADR-130 で経験した）。
    ///
    /// 条件: 断片は無名・アンカーなし・束ねなし。吸収先は確立した人物（名前かアンカーがあり
    /// `absorbTargetMinPhotos` 枚以上）。近さは `autoAbsorbBar` 以上かつ 2 位と `absorbMargin` 差。
    /// 同一写真の重なり・負例・「別人」記録があるものは対象外。
    @discardableResult
    func absorbFragments(limit: Int = FaceStore.absorbLimitPerRun) -> FragmentAbsorbResult {
        let photos = photoCountsByCluster()
        let clusters = allClusters()
        guard clusters.count >= 2 else {
            Diagnostics.mark("faces: absorb — skipped (clusters=\(clusters.count))")
            return FragmentAbsorbResult(absorbed: 0, people: 0, skipped: 0, skippedTooBig: 0)
        }
        let anchors = anchorsByCluster()
        let negatives = loadNegatives()
        let refKeysByCluster = memberRefKeysByCluster()
        let blocked = blockedPairs()

        var centroid: [Int: [Float]] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
        }
        // 吸収先＝確立した人物。ライバル判定は「3 枚以上の人物」全体で見る
        //（小さな別人に近い断片を、たまたま大きい人へ吸わせない）。
        let targets = clusters.filter {
            (photos[$0.clusterID] ?? 0) >= Self.absorbTargetMinPhotos
                && (($0.name?.isEmpty == false) || !(anchors[$0.clusterID] ?? []).isEmpty)
        }
        let rivals = clusters.filter { (photos[$0.clusterID] ?? 0) >= 3 }
        guard !targets.isEmpty else {
            // ⚠️ 黙って戻らない。**「走って 0 件」と「そもそも走っていない」は別**で、
            // ログに何も出ないと実機で見分けられない（実機 diagnostics-69 で実際に詰まった）。
            Diagnostics.mark("faces: absorb — 吸収先が無い（clusters=\(clusters.count) "
                             + "min=\(Self.absorbTargetMinPhotos)枚かつ命名/確認済み）")
            return FragmentAbsorbResult(absorbed: 0, people: 0, skipped: 0, skippedTooBig: 0)
        }

        let fragments = clusters.filter { c in
            let count = photos[c.clusterID] ?? 0
            return count >= 1 && count <= Self.absorbMaxPhotos
                && (c.name?.isEmpty ?? true) && c.personGroupID == nil
                && (anchors[c.clusterID] ?? []).isEmpty
        }
        var absorbed = 0, skipped = 0
        // 見送りの内訳（どの条件で落ちたのかが分からないと、次にどこを緩めるか決められない）。
        var belowBar = 0, marginal = 0, blockedCount = 0
        var into = Set<Int>()
        // 上限を上げれば対象になり得た数（無名・アンカーなしで、上限だけが理由の分）。
        let tooBig = clusters.filter { c in
            let count = photos[c.clusterID] ?? 0
            return count > Self.absorbMaxPhotos && count < Self.absorbTargetMinPhotos
                && (c.name?.isEmpty ?? true) && c.personGroupID == nil
                && (anchors[c.clusterID] ?? []).isEmpty
        }.count
        for fragment in fragments {
            guard absorbed < limit else { break }
            guard let vector = centroid[fragment.clusterID] else { continue }
            // 最も近い「吸収先」と、最も近い「その他の人物」（2 位）を出す。
            var best: (id: Int, sim: Float)?
            var runnerUp: Float = -1
            for rival in rivals where rival.clusterID != fragment.clusterID {
                guard let other = centroid[rival.clusterID] else { continue }
                let sim = FaceClustering.dot(vector, other)
                let isTarget = targets.contains { $0.clusterID == rival.clusterID }
                if isTarget, sim > (best?.sim ?? -1) {
                    if let previous = best { runnerUp = max(runnerUp, previous.sim) }
                    best = (rival.clusterID, sim)
                } else {
                    runnerUp = max(runnerUp, sim)
                }
            }
            guard let best, best.sim >= tuning.autoAbsorbBar else { skipped += 1; belowBar += 1; continue }
            // 紛らわしい（2 位が近い）なら人に尋ねる。
            guard best.sim - runnerUp >= Self.absorbMargin else { skipped += 1; marginal += 1; continue }
            // 同一写真・負例・「別人」記録があるものは触らない。
            let fragmentPhotos = refKeysByCluster[fragment.clusterID] ?? []
            guard fragmentPhotos.isDisjoint(with: refKeysByCluster[best.id] ?? []),
                  !blocked.contains(Self.pairKey(fragment.clusterID, best.id)),
                  let targetCentroid = centroid[best.id],
                  !FaceClustering.negativeRejects(vector, centroid: targetCentroid,
                                                  negatives: negatives,
                                                  sameThreshold: tuning.negativeSameThreshold)
            else { skipped += 1; blockedCount += 1; continue }

            // ⚠️ **機械の判断はジャーナルにもアンカーにも残さない**（ADR-152）。
            if mergeClusters(from: fragment.clusterID, into: best.id,
                             recordNotSameOnConflict: false, userInitiated: false) == nil {
                absorbed += 1
                into.insert(best.id)
            } else {
                skipped += 1
            }
        }
        if absorbed > 0 { try? modelContext.save(); clusteringCache = nil }
        // ⚠️ **0 件でも必ず記録する**（ADR-157）。上限（tooBig）と見送りの内訳は、
        // 「断片は何枚まで自動で寄せてよいか」を実測で決めるための材料そのもの（ADR-155）。
        Diagnostics.mark("faces: absorb — absorbed=\(absorbed) into=\(into.count) "
                         + "fragments=\(fragments.count) targets=\(targets.count) "
                         + "skipped=\(skipped)(bar=\(belowBar) margin=\(marginal) blocked=\(blockedCount)) "
                         + "tooBig=\(tooBig) bar=\(tuning.autoAbsorbBar)")
        return FragmentAbsorbResult(absorbed: absorbed, people: into.count,
                                    skipped: skipped, skippedTooBig: tooBig)
    }

    /// 「別人」記録と同一写真の印がある対（どちらも吸収しない）。
    private func blockedPairs() -> Set<String> {
        let rows = (countedFetchOptional(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.kind == "notSame" || $0.kind == "samePhotoBlock" }))) ?? []
        // 記録は埋め込みベースなので、ここでは重心一致で対を復元する（NotSameIndex と同じ考え方）。
        var pairs = Set<String>()
        let centroids = Dictionary(uniqueKeysWithValues: allClusters().compactMap { c in
            ClipMath.decodeHalf(c.sum).map { (c.clusterID, FaceClustering.normalized($0)) }
        })
        for row in rows {
            guard (row.profile ?? "facenet") == tuning.name,
                  let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding).map(FaceClustering.normalized),
                  let b = ClipMath.decodeHalf(wrong).map(FaceClustering.normalized) else { continue }
            let matchA = centroids.filter { FaceClustering.dot($0.value, a) >= 0.98 }.map(\.key)
            let matchB = centroids.filter { FaceClustering.dot($0.value, b) >= 0.98 }.map(\.key)
            for x in matchA { for y in matchB { pairs.insert(Self.pairKey(x, y)) } }
        }
        return pairs
    }

    static func pairKey(_ a: Int, _ b: Int) -> String { a < b ? "\(a)-\(b)" : "\(b)-\(a)" }
}
