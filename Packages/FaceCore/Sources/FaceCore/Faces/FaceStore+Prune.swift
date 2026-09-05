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

    /// - Parameter existingRefKeys: いま存在する写真（スキャナと同じ候補列挙）。
    /// - Returns: 消した数。候補が信用できない（欠けが上限超）ときは nil。
    func pruneMissingPhotos(existingRefKeys: Set<String>) -> (faces: Int, photos: Int, clusters: Int)? {
        let scanned = scannedRefKeys()
        let missing = scanned.subtracting(existingRefKeys)
        guard !missing.isEmpty else { return (0, 0, 0) }
        guard Double(missing.count) <= Double(scanned.count) * Self.pruneMaxFraction else {
            Self.log.error("faces: prune skipped — \(missing.count)/\(scanned.count) missing (candidates incomplete?)")
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

        // 顔が 1 つも残らなかった人物は消す（membership だけの顔も含めて数える）。
        var clustersRemoved = 0
        for clusterID in touched {
            guard let c = cluster(clusterID) else { clustersRemoved += 1; continue }
            let cid = clusterID
            let remaining = (try? modelContext.fetchCount(FetchDescriptor<DetectedFace>(
                predicate: #Predicate { $0.clusterID == cid }))) ?? 0
            if remaining == 0 {
                modelContext.delete(c)
                clustersRemoved += 1
            }
        }
        try? modelContext.save()
        clusteringCache = nil
        Self.log.info("faces: pruned \(facesRemoved) face(s) of \(missing.count) missing photo(s), "
                      + "\(clustersRemoved) empty cluster(s)")
        return (facesRemoved, missing.count, clustersRemoved)
    }
}
