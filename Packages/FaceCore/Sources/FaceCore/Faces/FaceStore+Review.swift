import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 人物レビュー（アクティブラーニング） 関連（extension 分割・ADR）。
extension FaceStore {
    // MARK: - 人物レビュー（A1/A2・ADR-46）

    /// レビューカードの生成。**判断が割れるケースだけ**を選ぶ（アクティブラーニング）:
    /// - A1 統合サジェスト: 重心類似が「合流の一歩手前」（しきい値−0.10 〜 しきい値）の
    ///   クラスタ対。「別人」と記録済みの対は出さない。
    /// - A2 境界の顔: クラスタ内で重心類似が最も低い（しきい値＋0.10 未満）未確認の顔
    ///   ＝混入している別人が最も出やすい位置。
    /// - Parameter excluding: 出題済み（既定回数見せたが答えられなかった）カード ID。
    ///   同じ質問を繰り返さず、次点の候補で埋める（実フィードバック対応）。
    func reviewItems(minFaces: Int, limit: Int = 30,
                     excluding: Set<String> = []) -> [FaceReviewItem] {
        let thr = calibratedThreshold()
        let clusters = allClusters().filter { $0.count >= minFaces }
        guard clusters.count >= 1 else { return [] }

        // 重心（正規化）と表示用の代表顔・メンバー写真集合（共起判定用）を用意。
        var centroid: [Int: [Float]] = [:]
        var coverFace: [Int: PersonInfo.Face] = [:]
        var name: [Int: String] = [:]
        var photoSets: [Int: Set<String>] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
            // 未命名は空（UI は名前ラベルを出さない。"Person N" は誰か分からず判断の助けにならない）。
            name[c.clusterID] = (c.name?.isEmpty == false) ? (c.name ?? "") : ""
            let members = faces(inCluster: c.clusterID)
            photoSets[c.clusterID] = Set(members.map(\.refKey))
            let cover = c.coverFaceID.flatMap { fid in members.first { $0.faceID == fid } }
                ?? Self.bestCoverFace(members)
            if let f = cover {
                coverFace[c.clusterID] = PersonInfo.Face(
                    faceID: f.faceID, refKey: f.refKey,
                    boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh))
            }
        }

        // 「別人」と記録済みの対（重心埋め込みで照合＝ID の揺れに強い）。
        let notSameRows = ((try? modelContext.fetch(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.kind == "notSame" }))) ?? []).compactMap {
            row -> ([Float], [Float])? in
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        func isMarkedNotSame(_ a: [Float], _ b: [Float]) -> Bool {
            for (ra, rb) in notSameRows {
                if (FaceClustering.dot(a, ra) >= 0.9 && FaceClustering.dot(b, rb) >= 0.9)
                    || (FaceClustering.dot(a, rb) >= 0.9 && FaceClustering.dot(b, ra) >= 0.9) {
                    return true
                }
            }
            return false
        }

        var items: [FaceReviewItem] = []

        // A1: 統合サジェスト（類似度の高い対から）。上限は設けない（帯域 [thr−0.10, 1.0]）:
        // 制約付き再クラスタは命名クラスタを別々の種として保持するため、しきい値**以上**の
        // 高類似ペアも統合されずに残り得る（従来は出題対象外だった実ギャップ）。
        // 共起抑制: 同じ写真に一緒に写った回数が一定以上のペアは**別人**（同一人物は
        // 1 枚に 1 回しか写れない）ので提案しない（兄弟の誤統合防止・ユーザー操作ゼロ）。
        let ids = clusters.map(\.clusterID)
        var mergeCandidates: [(a: Int, b: Int, sim: Float)] = []
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                guard let ca = centroid[ids[i]], let cb = centroid[ids[j]] else { continue }
                let sim = FaceClustering.dot(ca, cb)
                guard sim >= thr - 0.10, !isMarkedNotSame(ca, cb) else { continue }
                let coOccurrence = (photoSets[ids[i]] ?? []).intersection(photoSets[ids[j]] ?? []).count
                guard coOccurrence < Self.coOccurrenceNotSame else { continue }
                mergeCandidates.append((ids[i], ids[j], sim))
            }
        }
        for cand in mergeCandidates.sorted(by: { $0.sim > $1.sim }) {
            guard items.count < limit else { break }
            guard let fa = coverFace[cand.a], let fb = coverFace[cand.b] else { continue }
            let item = FaceReviewItem.samePerson(
                aClusterID: cand.a, aName: name[cand.a] ?? "", aFace: fa,
                bClusterID: cand.b, bName: name[cand.b] ?? "", bFace: fb,
                similarity: cand.sim)
            if excluding.contains(item.id) { continue }
            items.append(item)
        }

        // A2: 境界の顔（クラスタごとに最大 2・類似が低い順）。命名済みクラスタを優先。
        let ordered = clusters.sorted {
            (($0.name?.isEmpty == false) ? 0 : 1, -$0.count) < (($1.name?.isEmpty == false) ? 0 : 1, -$1.count)
        }
        for c in ordered {
            guard items.count < limit, let cen = centroid[c.clusterID] else { continue }
            var boundary: [(face: DetectedFace, sim: Float)] = []
            // 品質フロア未満の顔は出題しない（ADR-53 追補）。境界レビューは「最も疑わしい顔」を
            // 選ぶため、旧データに残る誤検出（模様等の偽陽性・低品質）がそのまま最優先で出て
            // 「顔じゃないカード」になる実障害があった。フロア未満は再スキャンで浄化されるまで
            // 表示にも出さない（ユーザーに判断を求める価値がない）。
            for f in faces(inCluster: c.clusterID)
                where f.confirmedAt == nil && f.quality >= Double(Self.qualityFloor) {
                guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
                let sim = FaceClustering.dot(FaceClustering.normalized(vec), cen)
                if sim < thr + 0.10 { boundary.append((f, sim)) }
            }
            guard let cover = coverFace[c.clusterID] else { continue }
            var perCluster = 0
            for entry in boundary.sorted(by: { $0.sim < $1.sim }) {
                guard items.count < limit, perCluster < 2 else { break }
                // 未命名（Person N）は name=nil ＝ UI が「代表の顔と並べて比較」カードにする
                //（名前を出しても誰か分からず答えられない・実フィードバック）。
                // 境界顔自身が代表と同一（1 枚だけのケース等）は比較にならないので出さない。
                let displayName = (c.name?.isEmpty == false) ? c.name : nil
                if displayName == nil && cover.faceID == entry.face.faceID { continue }
                let item = FaceReviewItem.isThisPerson(
                    face: PersonInfo.Face(faceID: entry.face.faceID, refKey: entry.face.refKey,
                                          boundingBox: CGRect(x: entry.face.bx, y: entry.face.by,
                                                              width: entry.face.bw, height: entry.face.bh)),
                    clusterID: c.clusterID, name: displayName,
                    coverFace: cover,
                    similarity: entry.sim)
                if excluding.contains(item.id) { continue }   // 出題済み → 次点で埋める
                items.append(item)
                perCluster += 1
            }
        }
        return items
    }

    // MARK: - 一括レビュー（ADR-67）

    /// 「この人と同じ人を、まとめて選ぶ」1 画面ぶんを作る。
    ///
    /// 基準（アンカー）は `anchorClusterID` 指定がなければ **命名済みで最大**、無ければ最大の
    /// クラスタ。候補は A1 と同じ帯（重心類似 ≥ しきい値−0.10）から、別人記録・共起 notSame を
    /// 除いて類似度降順に採る。1 回答で `limit` 件まで畳めるので、A1（1 回答＝1 統合）に対して
    /// 桁で効率が上がる。
    func batchReviewItem(minFaces: Int, anchorClusterID: Int? = nil,
                         limit: Int = 24) -> FaceBatchReviewItem? {
        let thr = calibratedThreshold()
        let clusters = allClusters().filter { $0.count >= minFaces }
        guard clusters.count >= 2 else { return nil }

        var centroid: [Int: [Float]] = [:]
        var cover: [Int: PersonInfo.Face] = [:]
        var photoSets: [Int: Set<String>] = [:]
        for c in clusters {
            guard let sum = ClipMath.decodeHalf(c.sum) else { continue }
            centroid[c.clusterID] = FaceClustering.normalized(sum)
            let members = faces(inCluster: c.clusterID)
            photoSets[c.clusterID] = Set(members.map(\.refKey))
            let pick = c.coverFaceID.flatMap { fid in members.first { $0.faceID == fid } }
                ?? Self.bestCoverFace(members)
            if let f = pick {
                cover[c.clusterID] = PersonInfo.Face(
                    faceID: f.faceID, refKey: f.refKey,
                    boundingBox: CGRect(x: f.bx, y: f.by, width: f.bw, height: f.bh))
            }
        }

        // アンカー: 指定 → 命名済みで最大 → 最大。
        let anchor: PersonCluster? = {
            if let id = anchorClusterID { return clusters.first { $0.clusterID == id } }
            let named = clusters.filter { $0.name?.isEmpty == false }
            return (named.isEmpty ? clusters : named).max { $0.count < $1.count }
        }()
        guard let anchor, let anchorCentroid = centroid[anchor.clusterID],
              let anchorFace = cover[anchor.clusterID] else { return nil }

        // 「別人」記録（A1 と同じ・重心埋め込みで照合）。
        let notSameRows = ((try? modelContext.fetch(FetchDescriptor<FaceCorrection>(
            predicate: #Predicate { $0.kind == "notSame" }))) ?? []).compactMap {
            row -> ([Float], [Float])? in
            guard let wrong = row.wrongEmbedding,
                  let a = ClipMath.decodeHalf(row.faceEmbedding),
                  let b = ClipMath.decodeHalf(wrong) else { return nil }
            return (FaceClustering.normalized(a), FaceClustering.normalized(b))
        }
        func isMarkedNotSame(_ a: [Float], _ b: [Float]) -> Bool {
            for (ra, rb) in notSameRows {
                if (FaceClustering.dot(a, ra) >= 0.9 && FaceClustering.dot(b, rb) >= 0.9)
                    || (FaceClustering.dot(a, rb) >= 0.9 && FaceClustering.dot(b, ra) >= 0.9) {
                    return true
                }
            }
            return false
        }

        let anchorPhotos = photoSets[anchor.clusterID] ?? []
        var candidates: [FaceBatchReviewItem.Candidate] = []
        for c in clusters where c.clusterID != anchor.clusterID {
            guard let cen = centroid[c.clusterID], let face = cover[c.clusterID] else { continue }
            let sim = FaceClustering.dot(anchorCentroid, cen)
            guard sim >= thr - 0.10, !isMarkedNotSame(anchorCentroid, cen) else { continue }
            // 共起（同じ写真に何度も一緒に写る）＝別人。兄弟の一括誤統合を防ぐ最後の砦。
            guard anchorPhotos.intersection(photoSets[c.clusterID] ?? []).count < Self.coOccurrenceNotSame
            else { continue }
            candidates.append(.init(clusterID: c.clusterID, face: face,
                                    count: c.count, similarity: sim))
        }
        guard !candidates.isEmpty else { return nil }
        candidates.sort { $0.similarity > $1.similarity }

        return FaceBatchReviewItem(
            anchorClusterID: anchor.clusterID,
            anchorName: (anchor.name?.isEmpty == false) ? (anchor.name ?? "") : "",
            anchorFace: anchorFace, anchorCount: anchor.count,
            candidates: Array(candidates.prefix(limit)))
    }
}
