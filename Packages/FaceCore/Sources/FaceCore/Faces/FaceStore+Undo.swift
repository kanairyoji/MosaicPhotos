import Foundation
import PerceptionCore
import SwiftData

// MARK: - 直前の判定を取り消す（ADR-136）

/// 取り消しのために控える「触る前の状態」。
///
/// ⚠️ 操作ごとに逆操作を書かない。統合の逆は「顔を戻す＋消えたクラスタ行を作り直す＋
/// 重心と名前を戻す＋記録した学習を消す」で、**逆操作を 6 種類書けば 6 種類ぶんバグる**。
/// 代わりに**触る前の行をそのまま控えて、書き戻す**（状態の復元）。増えた行は
/// 「控えた時点より後に作られたもの」で識別して消す。
struct FaceUndoRecord: Sendable {
    struct FaceSnap: Sendable {
        let faceID: String
        let clusterID: Int
        let confirmedAt: Date?
        let contributesToCentroid: Bool?
    }
    struct ClusterSnap: Sendable {
        let clusterID: Int
        let sum: Data
        let count: Int
        let name: String?
        let coverFaceID: String?
        let personGroupID: Int?
    }
    /// 画面に出す説明（例: 「太郎 と Person 9 を統合」）。
    let label: String
    let faces: [FaceSnap]
    let clusters: [ClusterSnap]
    /// これ以降に作られた `FaceCorrection`（学習）はこの操作のもの＝取り消しで消す。
    let startedAt: Date
    /// これより大きい clusterID は、この操作で新しく作られたもの。
    let maxClusterIDBefore: Int
}

extension FaceStore {

    /// 1 回ぶんの控えに含める顔の上限。これを超える操作は取り消しの対象にしない
    /// （数千枚の人物を丸ごと控えるのは、目的（直前の 1 手を戻す）に見合わない）。
    static let undoFaceLimit = 5000
    /// 控えておく手数。
    static let undoDepth = 10

    /// これから触る人物・顔の状態を控える（操作の**直前**に呼ぶ）。
    /// `clusterIDs` に挙げた人物のメンバーは全員控える（統合で移動するため）。
    func beginUndo(label: String, clusterIDs: [Int], faceIDs: [String] = []) {
        let ids = Array(Set(clusterIDs))
        var snaps: [FaceUndoRecord.FaceSnap] = []
        var seen = Set<String>()
        // ⚠️ クラスタごとに引かない（ADR-119）。1 回の fetch でまとめて取る。
        let byCluster = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { ids.contains($0.clusterID) }))) ?? []
        for f in byCluster where seen.insert(f.faceID).inserted {
            snaps.append(.init(faceID: f.faceID, clusterID: f.clusterID,
                               confirmedAt: f.confirmedAt,
                               contributesToCentroid: f.contributesToCentroid))
        }
        let extra = faceIDs.filter { !seen.contains($0) }
        if !extra.isEmpty {
            let rows = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
                predicate: #Predicate { extra.contains($0.faceID) }))) ?? []
            for f in rows where seen.insert(f.faceID).inserted {
                snaps.append(.init(faceID: f.faceID, clusterID: f.clusterID,
                                   confirmedAt: f.confirmedAt,
                                   contributesToCentroid: f.contributesToCentroid))
            }
        }
        guard snaps.count <= Self.undoFaceLimit else {
            Self.log.info("faces: undo skipped — too many faces (\(snaps.count))")
            return
        }
        let all = allClusters()
        // 触る人物に加え、**その顔が今いる人物**も控える（付け替えで両側の重心が動くため）。
        let touched = Set(ids).union(snaps.map(\.clusterID))
        let clusters = all.filter { touched.contains($0.clusterID) }.map {
            FaceUndoRecord.ClusterSnap(clusterID: $0.clusterID, sum: $0.sum, count: $0.count,
                                       name: $0.name, coverFaceID: $0.coverFaceID,
                                       personGroupID: $0.personGroupID)
        }
        undoStack.append(FaceUndoRecord(
            label: label, faces: snaps, clusters: clusters, startedAt: Date(),
            maxClusterIDBefore: all.map(\.clusterID).max() ?? -1))
        if undoStack.count > Self.undoDepth { undoStack.removeFirst() }
    }

    /// 直前の操作の説明（無ければ nil）。UI の「戻す」に出す。
    func lastUndoLabel() -> String? { undoStack.last?.label }

    /// 直前の操作を取り消す。戻した操作の説明を返す（何も無ければ nil）。
    func undoLast() -> String? {
        guard let record = undoStack.popLast() else { return nil }
        // 1) 顔を元の人物・確認状態へ戻す。
        let faceIDs = record.faces.map(\.faceID)
        let rows = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { faceIDs.contains($0.faceID) }))) ?? []
        var byID: [String: DetectedFace] = [:]
        for r in rows { byID[r.faceID] = r }
        for snap in record.faces {
            guard let face = byID[snap.faceID] else { continue }
            face.clusterID = snap.clusterID
            face.confirmedAt = snap.confirmedAt
            face.contributesToCentroid = snap.contributesToCentroid
        }
        // 2) 人物行（重心・名前・代表・束ね）を戻す。統合で消えた行はここで作り直す。
        var existing: [Int: PersonCluster] = [:]
        for c in allClusters() { existing[c.clusterID] = c }
        for snap in record.clusters {
            if let c = existing[snap.clusterID] {
                c.sum = snap.sum
                c.count = snap.count
                c.name = snap.name
                c.coverFaceID = snap.coverFaceID
                c.personGroupID = snap.personGroupID
            } else {
                modelContext.insert(PersonCluster(
                    clusterID: snap.clusterID, sum: snap.sum, count: snap.count,
                    name: snap.name, coverFaceID: snap.coverFaceID,
                    personGroupID: snap.personGroupID))
            }
        }
        // 3) この操作で記録した学習（負例・正例）を消す。
        let since = record.startedAt
        let added = (try? modelContext.fetch(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.createdAt >= since }))) ?? []
        for correction in added { modelContext.delete(correction) }
        // 4) この操作で新しく作られた人物のうち、顔が残っていない行を消す（分離の取り消し）。
        let ceiling = record.maxClusterIDBefore
        var faceCounts: [Int: Int] = [:]
        var d = FetchDescriptor<DetectedFace>()
        d.propertiesToFetch = [\.clusterID]
        for row in (try? modelContext.fetch(d)) ?? [] { faceCounts[row.clusterID, default: 0] += 1 }
        for c in allClusters() where c.clusterID > ceiling && (faceCounts[c.clusterID] ?? 0) == 0 {
            modelContext.delete(c)
        }
        try? modelContext.save()
        clusteringCache = nil
        negativesCache = nil
        thresholdCache = nil
        Self.log.info("faces: undo — \(record.label) (faces=\(record.faces.count) "
                      + "clusters=\(record.clusters.count) corrections=\(added.count))")
        return record.label
    }

    /// 取り消しの控えを捨てる（再クラスタ・再スキャンの後は、戻す先が変わっているため）。
    func clearUndo() { undoStack.removeAll() }
}
