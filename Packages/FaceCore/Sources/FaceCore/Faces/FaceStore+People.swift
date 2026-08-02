import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 取り出し・2 階層束ね・名前解決 関連（extension 分割・ADR）。
extension FaceStore {
    // MARK: - 取り出し（表示用）

    /// 「人物」とみなすクラスタ（メンバー数 `minFaces` 以上）を多い順に返す。
    /// 代表写真（cover）の優先順位: ユーザーが選んだ顔（`coverFaceID`・現存するもの）
    /// → **お気に入りマークの写真**の顔（`favoriteRefKeys`）→ 認識した写真の先頭。
    func peopleClusters(minFaces: Int = 3, favoriteRefKeys: Set<String> = []) -> [PersonInfo] {
        // 2 階層（ADR-61）: personGroupID が同じクラスタを 1 人物に束ねる（子供の時期クラスタ）。
        // nil のクラスタは従来どおり単独（1 クラスタ=1 人物）＝全 nil なら旧挙動と一致。
        var groups: [String: [PersonCluster]] = [:]
        var order: [String] = []
        for c in allClusters() {
            let key = c.personGroupID.map { "g\($0)" } ?? "c\(c.clusterID)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(c)
        }
        var result: [PersonInfo] = []
        for key in order {
            let clustersInGroup = groups[key]!
            // 束ね内の全クラスタの顔を集約し、写真キーを重複排除。
            var allFaces: [DetectedFace] = []
            for c in clustersInGroup { allFaces += faces(inCluster: c.clusterID) }
            var seen = Set<String>()
            var members: [String] = []
            for f in allFaces where seen.insert(f.refKey).inserted { members.append(f.refKey) }
            guard members.count >= minFaces else { continue }
            // 主クラスタ: 名前つき優先 → メンバー最多。表示 ID・名前・代表はここが持つ。
            let primary = clustersInGroup.first { $0.name?.isEmpty == false }
                ?? clustersInGroup.max { $0.count < $1.count } ?? clustersInGroup[0]
            let primaryFaces = faces(inCluster: primary.clusterID)
            // 自動選択は「笑顔＋高品質＋大きく写っている」顔を優先（face-info-expansion 優先度 5）。
            let cover = primary.coverFaceID.flatMap { fid in allFaces.first { $0.faceID == fid } }
                ?? Self.bestCoverFace(allFaces.filter { favoriteRefKeys.contains($0.refKey) })
                ?? Self.bestCoverFace(primaryFaces)
                ?? Self.bestCoverFace(allFaces)
            let box = cover.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
            result.append(PersonInfo(
                clusterID: primary.clusterID, name: primary.name, count: members.count,
                coverRefKey: cover?.refKey, coverBoundingBox: box, memberRefKeys: members,
                isGrouped: clustersInGroup.count > 1))
        }
        return result.sorted { $0.count > $1.count }
    }

    // MARK: - 2 階層の人物束ね（ADR-61）

    /// 複数クラスタを 1 人物に束ねる（**融合しない**＝各クラスタの純度を保ったまま personGroupID を
    /// 揃える）。ユーザーが「同じ子（成長で分裂）」と指定したときに呼ぶ。既存の束ねグループも巻き込む
    /// （推移的）。名前・代表は主クラスタが持つ（peopleClusters が解決）。
    func linkClusters(_ clusterIDs: [Int]) {
        let picked = clusterIDs.compactMap { cluster($0) }
        guard picked.count >= 2 else { return }
        let existingGroups = Set(picked.compactMap { $0.personGroupID })
        let gid = existingGroups.min() ?? (picked.map(\.clusterID).min() ?? picked[0].clusterID)
        var targets = Set(picked.map(\.clusterID))
        // 既存グループの他メンバーも同じ gid に寄せる（複数回の束ねで分断しない）。
        if !existingGroups.isEmpty {
            for c in allClusters() where c.personGroupID.map(existingGroups.contains) == true {
                targets.insert(c.clusterID)
            }
        }
        for c in allClusters() where targets.contains(c.clusterID) { c.personGroupID = gid }
        try? modelContext.save()
        clusteringCache = nil
    }

    /// 束ねから 1 クラスタを外す（別人だった等）。personGroupID を nil に戻す。
    func unlinkCluster(_ clusterID: Int) {
        cluster(clusterID)?.personGroupID = nil
        try? modelContext.save()
        clusteringCache = nil
    }

    /// ある人物（主クラスタ ID で指定）に束ねられた全クラスタ ID（自分含む）。
    func linkedClusterIDs(primary clusterID: Int) -> [Int] {
        guard let c = cluster(clusterID) else { return [clusterID] }
        guard let gid = c.personGroupID else { return [clusterID] }
        return allClusters().filter { $0.personGroupID == gid }.map(\.clusterID)
    }

    /// この写真に写っている**指定クラスタの**顔矩形（Vision 正規化・原点左下）。
    /// 人物アルバムで「どの顔をこの人物として認識したか」をチェックする用途なので、
    /// 同じ写真の複数の顔が同一クラスタに入っていても（混入の疑い）、
    /// **重心に最も近い 1 顔だけ**を返す（全部に枠が付くとどれがこの人物か
    /// 分からず目的を果たせない＝実フィードバック）。
    func faceBoxes(refKey: String, clusterID: Int) -> [CGRect] {
        // 2 階層束ね（ADR-61）: 束ねた人物は全時期クラスタの顔をこの人物として扱う。
        let groupIDs = Set(linkedClusterIDs(primary: clusterID))
        let members = faces(inPhoto: refKey).filter { groupIDs.contains($0.clusterID) }
        guard members.count > 1 else {
            return members.map { CGRect(x: $0.bx, y: $0.by, width: $0.bw, height: $0.bh) }
        }
        // 束ねグループの重心（属するクラスタ重心の平均）に最も近い 1 顔を選ぶ。
        var centroids: [[Float]] = []
        for gid in groupIDs {
            if let c = cluster(gid), let sum = ClipMath.decodeHalf(c.sum) {
                centroids.append(FaceClustering.normalized(sum))
            }
        }
        var best: (face: DetectedFace, sim: Float)?
        for f in members {
            guard let v = ClipMath.decodeHalf(f.embedding) else { continue }
            let nv = FaceClustering.normalized(v)
            let sim = centroids.map { FaceClustering.dot(nv, $0) }.max() ?? -1
            if best == nil || sim > best!.sim { best = (f, sim) }
        }
        let chosen = best?.face ?? members[0]
        return [CGRect(x: chosen.bx, y: chosen.by, width: chosen.bw, height: chosen.bh)]
    }

    /// クラスタの顔候補（写真ごとに 1 つ・代表写真ピッカー用）。
    func facesForCluster(clusterID: Int) -> [PersonInfo.Face] {
        var seen = Set<String>()
        var out: [PersonInfo.Face] = []
        for f in faces(inCluster: clusterID) where seen.insert(f.refKey).inserted {
            out.append(PersonInfo.Face(
                faceID: f.faceID, refKey: f.refKey,
                boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh)))
        }
        return out
    }

    /// clusterID → その人物の表示名（2 階層束ねを反映＝サブクラスタも主クラスタの名前）。
    /// 人物とみなす閾値 `minFaces` は**束ねグループの合計写真数**で判定する。未命名は "Person N"。
    /// 検索・名前表示が束ねた人物を 1 人として扱うための共通解決（ADR-61）。
    func personNameByCluster(minFaces: Int) -> [Int: String] {
        var groups: [String: [PersonCluster]] = [:]
        for c in allClusters() {
            let key = c.personGroupID.map { "g\($0)" } ?? "c\(c.clusterID)"
            groups[key, default: []].append(c)
        }
        var out: [Int: String] = [:]
        for (_, cs) in groups {
            var seen = Set<String>()
            for c in cs { for f in faces(inCluster: c.clusterID) { seen.insert(f.refKey) } }
            guard seen.count >= minFaces else { continue }
            let primary = cs.first { $0.name?.isEmpty == false }
                ?? cs.max { $0.count < $1.count } ?? cs[0]
            let name = primary.name ?? "Person \(primary.clusterID + 1)"
            for c in cs { out[c.clusterID] = name }
        }
        return out
    }

    /// 全スキャン済み写真の refKey → 人物表示名（自動アルバム生成の people 付与用）。
    /// 「人物」とみなせるクラスタ（minFaces 以上）のみ。未命名は "Person N"。2 階層束ね反映。
    func peopleNamesByRefKey(minFaces: Int) -> [String: [String]] {
        let nameByCluster = personNameByCluster(minFaces: minFaces)
        guard !nameByCluster.isEmpty else { return [:] }
        let faces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
        var out: [String: [String]] = [:]
        for f in faces {
            guard let name = nameByCluster[f.clusterID] else { continue }
            if out[f.refKey]?.contains(name) != true {
                out[f.refKey, default: []].append(name)
            }
        }
        return out
    }

    /// この写真に写っている「人物」の表示名（フル画像ビューの People 表示用）。2 階層束ね反映
    /// （束ねた人物は名前で重複排除＝サブクラスタが同じ写真に複数あっても 1 回）。
    func peopleNames(refKey: String, minFaces: Int) -> [String] {
        let nameByCluster = personNameByCluster(minFaces: minFaces)
        var out: [String] = []
        var seen = Set<String>()
        for f in faces(inPhoto: refKey) {
            guard let name = nameByCluster[f.clusterID], seen.insert(name).inserted else { continue }
            out.append(name)
        }
        return out
    }

    /// 代表写真（cover）を指定した顔に設定する。
    func setCover(clusterID: Int, faceID: String) {
        guard let c = cluster(clusterID) else { return }
        c.coverFaceID = faceID
        try? modelContext.save()
    }

}
