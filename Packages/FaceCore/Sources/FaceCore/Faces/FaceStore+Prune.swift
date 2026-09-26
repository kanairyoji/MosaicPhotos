import Foundation
import PerceptionCore
import SwiftData

/// 写真が無くなった顔の掃除。
///
/// 写真を削除・移動（Dropbox の配置替え＝ADR-175 など）・同期対象外にしても、顔台帳には
/// その写真の顔と走査記録が残る。残った顔は (1) 人物のメンバー数・重心に効き続け、
/// (2) 「似ている人」の顔一覧にサムネイルの出ない顔として並び、タップしても写真が無いので
/// 開けない（実フィードバック）。台帳（候補）と突き合わせて消す。
extension FaceStore {

    /// 消してよい上限（走査記録に対する割合）。これを超える欠けは「候補が揃っていない」
    /// （Dropbox 未ロード・写真アクセス制限）とみなして**何もしない**——実在する顔を消さない。
    static let pruneMaxFraction = 0.05

    /// - Parameters:
    ///   - existingRefKeys: いま存在する写真（スキャナと同じ候補列挙）。
    ///   - knownGone: 「無い」と**分かっている**写真（候補から意図して外したバックアップコピー等）。
    ///     こちらは安全弁（割合の上限）の対象外——理由が分かっているので数が多くても消してよい。
    /// - Returns: 消した数。候補が信用できない（説明のつかない欠けが上限超）ときは nil。
    func pruneMissingPhotos(existingRefKeys: Set<String>, knownGone: Set<String> = [])
        -> (faces: Int, photos: Int, clusters: Int)? {
        let scanned = scannedRefKeys()
        let missing = scanned.subtracting(existingRefKeys)
        guard !missing.isEmpty else { return (0, 0, 0) }
        let unexplained = missing.subtracting(knownGone)
        guard Double(unexplained.count) <= Double(scanned.count) * Self.pruneMaxFraction else {
            Self.log.error("faces: prune skipped — \(unexplained.count)/\(scanned.count) missing without a reason (candidates incomplete?)")
            return nil
        }

        var facesRemoved = 0
        var touched = Set<Int>()
        let keys = Array(missing)
        // IN 句は 500 件ずつ（SQLite の変数上限を跨がない）。
        for start in stride(from: 0, to: keys.count, by: 500) {
            let chunk = Array(keys[start..<min(start + 500, keys.count)])
            let faces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
                predicate: #Predicate { chunk.contains($0.refKey) }))) ?? []
            for face in faces {
                if face.clusterID >= 0, let vec = ClipMath.decodeHalf(face.embedding) {
                    // 前面の付け替えと同じ規則で重心から引く（寄与していない顔は引かない・ADR-66）。
                    removeFromCluster(clusterID: face.clusterID, vec: vec, quality: Float(face.quality),
                                      faceID: face.faceID, contributes: FaceStore.contributesToCentroid(face))
                    touched.insert(face.clusterID)
                }
                modelContext.delete(face)
                facesRemoved += 1
            }
            let markers = (try? modelContext.fetch(FetchDescriptor<ScannedPhoto>(
                predicate: #Predicate { chunk.contains($0.refKey) }))) ?? []
            for marker in markers { modelContext.delete(marker) }
        }
        try? modelContext.save()

        // ⚠️ 表明の国勢調査（ADR-233）。写真の整理は**利用者が意図していない副作用**で
        // 人物が消える経路なので、ここも前後で突き合わせる。
        let censusBefore = assertionCensus()
        // 顔が 1 つも残らなかった人物は消す（membership だけの顔も含めて数える）。
        // ⚠️ ユーザーが表明した人物（名前・束ね・代表写真・家族グループの所属）は空でも残す
        // （ADR-187/231）。⚠️ グループの集合は**ループの外で 1 回**作る（ADR-119）。
        // これが無いと、写真を消しただけで**家族グループから無名のメンバーが黙って消える**。
        let groupMembers = peopleGroupMemberClusterIDs()
        var clustersRemoved = 0
        for clusterID in touched {
            guard let c = cluster(clusterID) else { clustersRemoved += 1; continue }
            let cid = clusterID
            let remaining = (try? modelContext.fetchCount(FetchDescriptor<DetectedFace>(
                predicate: #Predicate { $0.clusterID == cid }))) ?? 0
            if remaining == 0, !FaceStore.isUserClaimed(c, peopleGroupMembers: groupMembers) {
                modelContext.delete(c)
                clustersRemoved += 1
            }
        }
        try? modelContext.save()
        clusteringCache = nil
        Self.log.info("faces: pruned \(facesRemoved) face(s) of \(missing.count) missing photo(s), "
                      + "\(clustersRemoved) empty cluster(s)")
        reportAssertionCensus("prune", before: censusBefore)
        return (facesRemoved, missing.count, clustersRemoved)
    }

    /// **孤児の顔**（消えたクラスタ ID を指したままの顔）を未割当に戻す（ADR-187）。
    /// 以前はクラスタ行が消えても顔の clusterID が残り、その ID が別人に再利用されると
    /// 別人のアルバムへ黙って合流していた。未割当に戻せば次の再クラスタで正しい場所へ入る。
    /// - Returns: 戻した顔の数。
    func repairOrphanFaces() -> Int {
        let live = Set(allClusters().map(\.clusterID))
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { $0.clusterID >= 0 })
        d.propertiesToFetch = [\.clusterID]
        let faces = (try? modelContext.fetch(d)) ?? []
        var fixed = 0
        for f in faces where !live.contains(f.clusterID) {
            f.clusterID = FaceClustering.unassigned
            f.contributesToCentroid = false
            fixed += 1
        }
        if fixed > 0 {
            try? modelContext.save()
            clusteringCache = nil
            Self.log.error("faces: repaired \(fixed) orphan face(s) pointing at deleted clusters")
        }
        return fixed
    }

    /// テスト用: クラスタ行だけを消す（顔は残る＝孤児を作る）。
    func deleteClusterRowForTesting(_ clusterID: Int) {
        if let c = cluster(clusterID) { modelContext.delete(c); try? modelContext.save(); clusteringCache = nil }
    }
}
