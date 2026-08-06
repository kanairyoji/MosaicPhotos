import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 制約付き再クラスタ・版数移行・リセット 関連（extension 分割・ADR）。
extension FaceStore {
    // MARK: - 制約付き再クラスタリング（B2・ADR-46）

    /// 全顔を**制約つきで**割り当て直す。逐次クラスタリングの順序依存（早い段階の誤りを
    /// 後から直せない）を断つ夜間ジョブ。
    /// - 種クラスタ: 命名済み or 確認顔ありのクラスタは **ID・名前・代表を保持**し、
    ///   確認顔（アンカー）を must-link として先に固定する。
    /// - 残りの顔を**品質降順**に割り当て（高品質の顔が先にクラスタの核を作る）。
    ///   しきい値は校正済み・負例も適用。
    /// 戻り値: (クラスタ数, 割り当てが変わった顔数)。
    func rebuildClusters() -> (clusters: Int, moved: Int) {
        let allFaces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
        guard !allFaces.isEmpty else { return (0, 0) }
        let thr = calibratedThreshold()
        let negatives = loadNegatives()
        let existing = allClusters()
        let maxExistingID = existing.map(\.clusterID).max() ?? -1

        // 1) 種クラスタ（命名済み or 確認顔あり）: アンカーだけから重心を作り直す。
        //    アンカーが無い（名前のみ）の種は現重心を 1 票として方向を維持する。
        var seeds: [FaceClustering.Cluster] = []
        var seedIDs = Set<Int>()
        var confirmedFaceIDs = Set<String>()
        for c in existing {
            let members = faces(inCluster: c.clusterID)
            let anchors = members.filter { $0.confirmedAt != nil }
            let isSeed = (c.name?.isEmpty == false) || !anchors.isEmpty
            guard isSeed else { continue }
            var sum: [Float] = []
            var count = 0
            var protos: [[Float]] = []
            for a in anchors {
                guard let vec = ClipMath.decodeHalf(a.embedding) else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: vec.count) }
                let added = FaceClustering.adding(vec, toSum: sum, count: count,
                                                  quality: Float(a.quality))
                sum = added.sum
                count = added.count
                protos.append(FaceClustering.normalized(vec))
                confirmedFaceIDs.insert(a.faceID)
            }
            if sum.isEmpty {
                guard let cur = ClipMath.decodeHalf(c.sum) else { continue }
                sum = FaceClustering.normalized(cur)   // 現重心を 1 票（方向のみ維持）
                count = 1
            }
            seeds.append(FaceClustering.Cluster(
                id: c.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: count, faceIDs: [], prototypes: protos))
            seedIDs.insert(c.clusterID)
        }

        // 2) 残りの顔を品質降順に割り当て（新規クラスタ ID は既存の最大より先から）。
        var clustering = FaceClustering(threshold: thr, qualityFloor: Self.qualityFloor,
                                        seedClusters: seeds, minimumNextID: maxExistingID + 1)
        clustering.assignMargin = tuning.assignMargin   // マージンゲート（ADR-57）
        clustering.sizeAdaptiveMarginMax = tuning.sizeAdaptiveMarginMax   // サイズ適応（ADR-58）
        clustering.negativeSameThreshold = tuning.negativeSameThreshold
        // サイズ適応マージンの免除（ADR-68・少人数ライブラリ限定）
        clustering.rivalAwareSizeMargin = Self.rivalAwareSizeMargin
        clustering.rivalAwareSizeMarginMaxPeople = Self.rivalAwareSizeMarginMaxPeople
        clustering.rivalAlikeMargin = tuning.rivalAlikeMargin
        // 実効しきい値の頭打ち（ADR-68 追補・少人数ライブラリ限定）。しきい値は校正で
        // 上がり得るので、そこへサイズ加算が乗って跳ね上がるのを止める。
        if Self.capEffectiveThresholdWhenFewPeople {
            clustering.effectiveThresholdCap = clustering.threshold
            clustering.effectiveThresholdCapMaxPeople = Self.effectiveThresholdCapMaxPeople
        }
        let pending = allFaces.filter { !confirmedFaceIDs.contains($0.faceID) }
            .sorted { $0.quality > $1.quality }
        // 同一写真 cannot-link（recordScan と同じ制約を全体再割り当てにも）。
        // 確認顔は種クラスタに残るため、その写真×クラスタの占有を先に登録する。
        var usedByPhoto: [String: Set<Int>] = [:]
        for f in allFaces where confirmedFaceIDs.contains(f.faceID) && f.clusterID >= 0 {
            usedByPhoto[f.refKey, default: []].insert(f.clusterID)
        }
        var newAssignment: [String: Int] = [:]
        for f in pending {
            guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            let cid = clustering.assign(
                faceID: f.faceID, embedding: vec,
                quality: Float(f.quality), negatives: negatives,
                excludedClusterIDs: usedByPhoto[f.refKey] ?? [])
            newAssignment[f.faceID] = cid
            if cid >= 0 { usedByPhoto[f.refKey, default: []].insert(cid) }
        }

        // 第2パス（ADR-66・recall 回復）: 品質フロア未満で捨てていた顔（横顔・ぶれ・小さめ等・埋め込みは
        // ある）を、**重心を汚さず**最寄り人物へ membership だけ割り当てる。純度は不変（sum/count 不変）。
        // 「人が写っているのに People に出ない」を減らす。データセット計測で閾値 0.55 を採用。
        for f in pending where (newAssignment[f.faceID] ?? FaceClustering.unassigned) < 0
            && Float(f.quality) < Self.qualityFloor {
            guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            let cid = clustering.assignMembershipOnly(
                faceID: f.faceID, embedding: vec,
                excludedClusterIDs: usedByPhoto[f.refKey] ?? [],
                threshold: tuning.secondPassThreshold)
            if cid >= 0 {
                newAssignment[f.faceID] = cid
                usedByPhoto[f.refKey, default: []].insert(cid)
            }
        }

        // 3) 書き戻し: 顔の clusterID（確認顔は種のまま）・種以外の旧クラスタ行は削除して再作成。
        var moved = 0
        for f in allFaces {
            let newID = confirmedFaceIDs.contains(f.faceID) ? f.clusterID
                : (newAssignment[f.faceID] ?? FaceClustering.unassigned)
            if f.clusterID != newID { moved += 1 }
            f.clusterID = newID
        }
        for c in existing where !seedIDs.contains(c.clusterID) {
            modelContext.delete(c)
        }
        persist(clustering)
        try? modelContext.save()
        clusteringCache = nil
        Self.log.info("faces: rebuild — clusters=\(clustering.clusters.count) moved=\(moved) thr=\(thr)")
        return (clustering.clusters.count, moved)
    }

    /// 全消去（再スキャン用）。
    /// ⚠️ 修正ジャーナル（FaceCorrection）は**消さない**（ADR-45）。負例は埋め込みキーなので、
    /// 再スキャン中の割り当てで自動的に再適用され、既知の誤りが再発しない。
    // MARK: - スキャン版数移行（名前の持ち越し・ADR-51）

    /// 命名済みクラスタのスナップショット（版上げ再スキャンの前に取得）。
    /// メンバー refKey は照合に十分な数（既定 500）に丸める。
    func namedClusterEntries(maxMembers: Int = 500) -> [(name: String, memberRefKeys: [String])] {
        var out: [(name: String, memberRefKeys: [String])] = []
        for c in allClusters() {
            guard let name = c.name, !name.isEmpty else { continue }
            var seen = Set<String>()
            var keys: [String] = []
            for f in faces(inCluster: c.clusterID) where seen.insert(f.refKey).inserted {
                keys.append(f.refKey)
            }
            out.append((name, Array(keys.prefix(maxMembers))))
        }
        return out
    }

    /// 再スキャン後の名前の再適用。旧クラスタのメンバー写真（refKey）との重なりが最大の
    /// 新クラスタへ名前を戻す（写真は再スキャンしても変わらない＝安定キー）。
    /// 一致条件: 重なり ≥ max(2, 旧メンバーの 20%)。スキャンが数晩に分かれても、
    /// 条件を満たした分から段階的に戻る。戻り値は**未適用の残り**（次回セッションで再試行）。
    func reapplyNames(_ entries: [(name: String, memberRefKeys: [String])])
        -> [(name: String, memberRefKeys: [String])] {
        var remaining: [(name: String, memberRefKeys: [String])] = []
        var takenNames = Set(allClusters().compactMap { c -> String? in
            (c.name?.isEmpty == false) ? c.name : nil
        })
        for entry in entries {
            // 既に同名クラスタがある（ユーザーが手で付け直した等）→ 消化済み扱い。
            if takenNames.contains(entry.name) { continue }
            let keys = entry.memberRefKeys
            let rows = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
                predicate: #Predicate { keys.contains($0.refKey) && $0.clusterID >= 0 }))) ?? []
            var overlap: [Int: Set<String>] = [:]
            for f in rows { overlap[f.clusterID, default: []].insert(f.refKey) }
            let need = max(2, entry.memberRefKeys.count / 5)
            if let best = overlap.max(by: { $0.value.count < $1.value.count }),
               best.value.count >= need,
               let c = cluster(best.key), c.name?.isEmpty ?? true {
                c.name = entry.name
                takenNames.insert(entry.name)
                continue
            }
            remaining.append(entry)
        }
        try? modelContext.save()
        return remaining
    }

    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        try? modelContext.save()
        clusteringCache = nil
        negativesCache = nil   // 次スキャンで DB から読み直す（ジャーナルは残存）
    }

    /// 修正ジャーナルも含めた完全消去（Developer Options の「学習もリセット」用）。
    func resetIncludingCorrections() {
        try? modelContext.delete(model: FaceCorrection.self)
        reset()
    }
}
