import CoreGraphics
import Foundation
import SwiftData

/// 家族共有（ADR-112）向けの顔シグナル輸出入。
/// - 輸出: 共有セットのサイドカーへ載せる顔検出結果（bbox・埋め込み・品質・撮影日）を
///   refKey 指定で取り出す。クラスタ ID・人物名は**含めない**（受信側は自分のクラスタに
///   自分で割り当てる）。
/// - 取り込みは既存の `recordScans` を使う（マーカーで二重記録を防ぎ、逐次クラスタリングで
///   受信側の人物へ自然に合流する）。
extension FaceStore {

    /// refKey → 検出顔シグナル。スキャン済みで顔がある写真だけ返す。
    ///
    /// ⚠️ `DetectedFace.refKey` は非インデックスなので、**per-key の predicate 検索は
    /// 1 キーごとに全表走査**になる（数千キー × 数万行で「反映中が終わらない」実障害）。
    /// 少数キーは per-key、多数キーは全件 1 回 fetch → メモリで絞る（`backupRefs` と同じ手筋）。
    func faceSignals(forRefKeys keys: [String],
                     includeNames: Bool = false) -> [String: [DetectedFaceSignal]] {
        guard !keys.isEmpty else { return [:] }
        let wanted = Set(keys)
        var out: [String: [DetectedFaceSignal]] = [:]

        // 人物名は**クラスタ 1 回の読み出し**で引く（顔ごとに引くと規模比例・ADR-119）。
        // 束ね（ADR-61）は主クラスタが名前を持つので、束ね先の名前も見えるようにする。
        var nameByCluster: [Int: String] = [:]
        if includeNames {
            var groupName: [Int: String] = [:]
            let clusters = allClusters()
            for c in clusters {
                guard let name = c.name, !name.isEmpty else { continue }
                nameByCluster[c.clusterID] = name
                if let gid = c.personGroupID { groupName[gid] = name }
            }
            for c in clusters where nameByCluster[c.clusterID] == nil {
                if let gid = c.personGroupID, let name = groupName[gid] {
                    nameByCluster[c.clusterID] = name
                }
            }
        }

        func append(_ face: DetectedFace) {
            out[face.refKey, default: []].append(DetectedFaceSignal(
                boundingBox: CGRect(x: face.bx, y: face.by, width: face.bw, height: face.bh),
                embedding: face.embedding,
                quality: Float(face.quality),
                hasSmile: face.hasSmile,
                captureDate: face.captureDate,
                personName: nameByCluster[face.clusterID]))
        }

        if wanted.count <= 50 {
            for key in wanted {
                let refKey = key
                let faces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
                    predicate: #Predicate { $0.refKey == refKey }))) ?? []
                faces.forEach(append)
            }
        } else {
            let all = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
            for face in all where wanted.contains(face.refKey) { append(face) }
        }
        return out
    }

    /// 未スキャンの refKey だけを返す（取り込み前のフィルタ用）。
    func unscannedRefKeys(from keys: [String]) -> [String] {
        guard !keys.isEmpty else { return [] }
        let scanned = scannedRefKeys()
        return keys.filter { !scanned.contains($0) }
    }

    /// 家族のサイドカーに入っていた人物名を、取り込んだ顔の所属クラスタへ**提案として**付ける。
    ///
    /// ⚠️ **既に名前がある人物は触らない**。名前は持ち主の判断であり、受信のたびに相手の
    /// 呼び方へ書き換わるのは事故に近い（「パパ」と「◯◯さん」が行き来する）。
    /// 名前を付けるのは「無名のクラスタ」に限り、同じ人物に複数の候補が来たら**多数決**で決める
    /// （1 枚の外れ値で人物名が決まらないように）。
    /// - Returns: 新しく名前が付いた人物の数。
    @discardableResult
    func applySharedNames(_ batch: [(refKey: String, faces: [DetectedFaceSignal])]) -> Int {
        // refKey → その写真で提案された名前（顔の並び順は recordScans と同じ）。
        var proposals: [String: [String]] = [:]
        for entry in batch {
            let names = entry.faces.compactMap(\.personName)
            if !names.isEmpty { proposals[entry.refKey] = names }
        }
        guard !proposals.isEmpty else { return 0 }

        // 取り込んだ顔の所属を引く（1 回の fetch）。
        let keys = Set(proposals.keys)
        var d = FetchDescriptor<DetectedFace>(predicate: #Predicate { keys.contains($0.refKey) })
        d.propertiesToFetch = [\.refKey, \.clusterID, \.faceID]
        let rows = (countedFetchOptional(d)) ?? []

        // クラスタごとに候補名を集める（同じ写真の顔は faceID 順＝記録順に対応させる）。
        var votes: [Int: [String: Int]] = [:]
        for (refKey, names) in proposals {
            let faces = rows.filter { $0.refKey == refKey }.sorted { $0.faceID < $1.faceID }
            for (index, face) in faces.enumerated() where index < names.count {
                guard face.clusterID >= 0 else { continue }
                votes[face.clusterID, default: [:]][names[index], default: 0] += 1
            }
        }
        guard !votes.isEmpty else { return 0 }

        var applied = 0
        let clusters = allClusters()
        for cluster in clusters where (cluster.name?.isEmpty ?? true) {
            guard let tally = votes[cluster.clusterID],
                  let winner = tally.max(by: { $0.value < $1.value })?.key else { continue }
            cluster.name = winner
            applied += 1
        }
        if applied > 0 {
            try? modelContext.save()
            clusteringCache = nil
        }
        return applied
    }
}
