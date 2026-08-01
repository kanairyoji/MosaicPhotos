import Foundation

/// クラスタリングの**評価用バリアント**（ADR-57 系統1・純ロジック）。
/// ハーネス（FaceAccuracyEvalTests）で計測して勝ったものだけを本番へ組み込む。
/// P3（推移的連鎖統合）が雪崩統合で失敗した教訓から、いずれも**推移性を持たない**
/// 局所判定のみで再現率を取り返すことを狙う。
public enum FaceClusteringVariants {

    /// A) マージンゲート付き貪欲: 1 位クラスタと 2 位クラスタの類似度差が `margin` 未満
    /// （＝どちらの人物か紛らわしい）の顔は合流させず新規クラスタにする。
    /// 兄弟のような「両方にそこそこ似ている」顔の引き込み（混入の主因）を防ぐ。
    public static func marginGatedCluster(_ faces: [(faceID: String, embedding: [Float])],
                                          threshold: Float, margin: Float,
                                          qualityFloor: Float = 0.40,
                                          qualities: [String: Float] = [:]) -> [FaceClustering.Cluster] {
        var clusters: [FaceClustering.Cluster] = []
        var nextID = 0
        for f in faces {
            let quality = qualities[f.faceID] ?? 1
            guard quality >= qualityFloor else { continue }
            let v = FaceClustering.normalized(f.embedding)
            let scored = clusters.indices
                .map { (index: $0, sim: FaceClustering.dot(v, clusters[$0].centroid)) }
                .sorted { $0.sim > $1.sim }
            let best = scored.first
            let second = scored.count >= 2 ? scored[1].sim : -1
            // 1 位がしきい値以上、かつ「2 位もしきい値以上で差が margin 未満」でなければ合流。
            if let best, best.sim >= threshold,
               !(second >= threshold && best.sim - second < margin) {
                let w = max(quality, 0.01)
                for i in clusters[best.index].sum.indices { clusters[best.index].sum[i] += v[i] * w }
                clusters[best.index].count += 1
                clusters[best.index].faceIDs.append(f.faceID)
                clusters[best.index].centroid = FaceClustering.normalized(clusters[best.index].sum)
            } else {
                let w = max(quality, 0.01)
                clusters.append(FaceClustering.Cluster(
                    id: nextID, centroid: v, sum: v.map { $0 * w }, count: 1, faceIDs: [f.faceID]))
                nextID += 1
            }
        }
        return clusters
    }

    /// B) 二段階＋比率テスト: まず高しきい値で「確実な核」（2 顔以上）だけを作り、
    /// 残りの顔は「1 位の核に十分近く、かつ 2 位より margin 以上近い」ときだけ帰属させる。
    /// 核の重心は帰属で動かさない（ドリフトによる引き込み連鎖を断つ）。
    public static func twoStageCluster(_ faces: [(faceID: String, embedding: [Float])],
                                       coreThreshold: Float, attachThreshold: Float, margin: Float,
                                       qualityFloor: Float = 0.40,
                                       qualities: [String: Float] = [:]) -> [FaceClustering.Cluster] {
        // 第 1 段: 高純度の核。
        let stage1 = FaceClustering.clusterAll(faces, threshold: coreThreshold,
                                               qualityFloor: qualityFloor, qualities: qualities)
        var cores = stage1.filter { $0.count >= 2 }
        let coreFaceIDs = Set(cores.flatMap(\.faceIDs))
        var nextID = (stage1.map(\.id).max() ?? -1) + 1

        // 第 2 段: 残りの顔を固定核へ帰属（比率テスト）。外れは単独クラスタ。
        var singles: [FaceClustering.Cluster] = []
        for f in faces where !coreFaceIDs.contains(f.faceID) {
            let quality = qualities[f.faceID] ?? 1
            guard quality >= qualityFloor else { continue }
            let v = FaceClustering.normalized(f.embedding)
            let scored = cores.indices
                .map { (index: $0, sim: FaceClustering.dot(v, cores[$0].centroid)) }
                .sorted { $0.sim > $1.sim }
            let best = scored.first
            let second = scored.count >= 2 ? scored[1].sim : -1
            if let best, best.sim >= attachThreshold, best.sim - second >= margin {
                cores[best.index].faceIDs.append(f.faceID)
                cores[best.index].count += 1   // 重心は据え置き（核を汚さない）
            } else {
                singles.append(FaceClustering.Cluster(
                    id: nextID, centroid: v, sum: v, count: 1, faceIDs: [f.faceID]))
                nextID += 1
            }
        }
        return cores + singles
    }

    /// C) ロバスト重心（中央値）2 パス: 通常の貪欲でまとめた後、各クラスタの重心を
    /// **要素ごとの中央値**で作り直して全顔を再帰属する。平均重心は混入 1 つに
    /// 引っ張られるが、中央値は外れ顔の影響を受けにくい。
    public static func medianRefinedCluster(_ faces: [(faceID: String, embedding: [Float])],
                                            threshold: Float,
                                            qualityFloor: Float = 0.40,
                                            qualities: [String: Float] = [:]) -> [FaceClustering.Cluster] {
        let stage1 = FaceClustering.clusterAll(faces, threshold: threshold,
                                               qualityFloor: qualityFloor, qualities: qualities)
        guard !stage1.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: faces.map { ($0.faceID, $0.embedding) })

        // 中央値重心を作る。
        var centroids: [(id: Int, centroid: [Float])] = []
        for c in stage1 {
            let members = c.faceIDs.compactMap { byID[$0] }.map(FaceClustering.normalized)
            guard let dims = members.first?.count, !members.isEmpty else { continue }
            var median = [Float](repeating: 0, count: dims)
            for d in 0..<dims {
                let column = members.map { $0[d] }.sorted()
                median[d] = column[column.count / 2]
            }
            centroids.append((c.id, FaceClustering.normalized(median)))
        }

        // 全顔を中央値重心へ再帰属（順序非依存）。届かない顔は単独クラスタ。
        var faceIDsByCluster: [Int: [String]] = [:]
        var nextID = (stage1.map(\.id).max() ?? -1) + 1
        for f in faces {
            let quality = qualities[f.faceID] ?? 1
            guard quality >= qualityFloor else { continue }
            let v = FaceClustering.normalized(f.embedding)
            let best = centroids.map { (id: $0.id, sim: FaceClustering.dot(v, $0.centroid)) }
                .max { $0.sim < $1.sim }
            if let best, best.sim >= threshold {
                faceIDsByCluster[best.id, default: []].append(f.faceID)
            } else {
                faceIDsByCluster[nextID] = [f.faceID]
                nextID += 1
            }
        }
        let centroidByID = Dictionary(uniqueKeysWithValues: centroids.map { ($0.id, $0.centroid) })
        return faceIDsByCluster.map { id, members in
            let centroid = centroidByID[id]
                ?? members.first.flatMap { byID[$0] }.map(FaceClustering.normalized) ?? []
            return FaceClustering.Cluster(id: id, centroid: centroid, sum: centroid,
                                          count: members.count, faceIDs: members)
        }
    }
}
