import PerceptionCore
import CoreGraphics
import Foundation
import MosaicSupport
import SwiftData

/// `FaceStore` の 付け替え・統合・修正ジャーナル 関連（extension 分割・ADR）。
extension FaceStore {
    // MARK: - 付け替え（「この人は別の人」）

    /// 顔を別の人物へ付け替える。`toClusterID` が nil なら新規人物を作る。
    /// 重心演算は `FaceClustering.adding/removing`（`assign` と同じ正規化規則）に委譲する。
    func reassignFace(faceID: String, toClusterID: Int?) {
        guard let face = face(byID: faceID),
              let vec = ClipMath.decodeHalf(face.embedding) else { return }
        let oldCID = face.clusterID
        guard oldCID != toClusterID else { return }
        let quality = Float(face.quality)

        // ADR-45: 「この顔はこの人ではない」を負例として記録（付け替え元に**他の顔がいた**とき、
        // ＝ 誤って一緒にされていたときだけ）。単独クラスタからの分離は誤りの信号ではないので除外。
        if let oldCluster = cluster(oldCID), oldCluster.count >= 2,
           let oldSum = ClipMath.decodeHalf(oldCluster.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(oldSum))
            recordCorrection(kind: "reassign", faceEmbedding: face.embedding,
                             wrongEmbedding: ClipMath.encodeHalf(oldSum), similarity: sim)
        }
        // ADR-46: 付け替え先を**ユーザーが選んだ**＝「この顔はこの人」という確認。
        // 正例として記録し、アンカー（マルチプロトタイプ）にする。
        if let toClusterID, let target = cluster(toClusterID),
           let targetSum = ClipMath.decodeHalf(target.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(targetSum))
            recordCorrection(kind: "confirm", faceEmbedding: face.embedding,
                             wrongEmbedding: nil, similarity: sim)
            face.confirmedAt = Date()
        }

        removeFromCluster(clusterID: oldCID, vec: vec, quality: quality, faceID: faceID)
        let targetCID = toClusterID ?? nextClusterID()
        addToCluster(clusterID: targetCID, vec: vec, quality: quality, faceID: faceID)
        face.clusterID = targetCID
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次回に再構築）
    }

    /// 「この写真はこの人？」に **はい**（A2・ADR-46）。顔を確認済み（アンカー）にし、
    /// 正例（顔×所属クラスタ重心の類似）をしきい値校正の材料として記録する。
    func confirmFace(faceID: String) {
        guard let face = face(byID: faceID),
              let vec = ClipMath.decodeHalf(face.embedding),
              let c = cluster(face.clusterID),
              let sum = ClipMath.decodeHalf(c.sum) else { return }
        let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                     FaceClustering.normalized(sum))
        recordCorrection(kind: "confirm", faceEmbedding: face.embedding,
                         wrongEmbedding: nil, similarity: sim)
        face.confirmedAt = Date()
        try? modelContext.save()
    }

    /// 「同じ人物？」に **いいえ**（A1・ADR-46）。2 クラスタを「別人」として記録する。
    /// 以後この対は (1) 統合サジェストに出さない、(2) 双方向の負例として合流を拒否する。
    func markNotSamePerson(clusterA: Int, clusterB: Int,
                           confidence: AnswerConfidence = .high) {
        guard let a = cluster(clusterA), let b = cluster(clusterB),
              let aSum = ClipMath.decodeHalf(a.sum), let bSum = ClipMath.decodeHalf(b.sum) else { return }
        let sim = FaceClustering.dot(FaceClustering.normalized(aSum),
                                     FaceClustering.normalized(bSum))
        recordCorrection(kind: "notSame", faceEmbedding: ClipMath.encodeHalf(aSum),
                         wrongEmbedding: ClipMath.encodeHalf(bSum), similarity: sim,
                         confidence: confidence)
        try? modelContext.save()
    }

    /// 回答の確度（ADR-68 追補6）。`FaceCorrection.confidence` に記録し、学習で重み付けする。
    enum AnswerConfidence: Double, Sendable {
        /// 1 対 1 の確認・手動操作＝判断材料が揃っている。
        case high = 1.0
        /// まとめて確認＝小さなアバターを一覧から選ぶ。取り違えが起こりやすく件数も多い。
        case batch = 0.4
    }

    /// 修正ジャーナルへ 1 件追記（ADR-45/46）。負例・校正キャッシュを無効化する。
    func recordCorrection(kind: String, faceEmbedding: Data, wrongEmbedding: Data?,
                          similarity: Float? = nil,
                          confidence: AnswerConfidence = .high) {
        modelContext.insert(FaceCorrection(
            id: UUID().uuidString, kind: kind,
            faceEmbedding: faceEmbedding, wrongEmbedding: wrongEmbedding,
            similarity: similarity.map(Double.init), confidence: confidence.rawValue,
            profile: tuning.name, createdAt: Date()))
        negativesCache = nil
        thresholdCache = nil
        clusteringCache = nil   // しきい値が変わり得るため次スキャンで再構築
    }

    func nextClusterID() -> Int {
        (allClusters().map(\.clusterID).max() ?? -1) + 1
    }

    func removeFromCluster(clusterID: Int, vec: [Float], quality: Float, faceID: String) {
        guard let c = cluster(clusterID) else { return }
        guard let sum = ClipMath.decodeHalf(c.sum),
              let updated = FaceClustering.removing(vec, fromSum: sum, count: c.count, quality: quality) else {
            // 最後の 1 顔（または sum 破損）＝クラスタごと削除。
            modelContext.delete(c)
            return
        }
        c.sum = ClipMath.encodeHalf(updated.sum)
        c.count = updated.count
        if c.coverFaceID == faceID {
            // 代表顔が抜けたら未設定に戻し、読み出し時の自動選択（お気に入り優先→先頭）に任せる。
            c.coverFaceID = nil
        }
    }

    func addToCluster(clusterID: Int, vec: [Float], quality: Float, faceID: String) {
        if let c = cluster(clusterID) {
            if let sum = ClipMath.decodeHalf(c.sum) {
                let updated = FaceClustering.adding(vec, toSum: sum, count: c.count, quality: quality)
                c.sum = ClipMath.encodeHalf(updated.sum)
                c.count = updated.count
            } else {
                c.count += 1
            }
        } else {
            let seeded = FaceClustering.adding(vec, toSum: [Float](repeating: 0, count: vec.count),
                                               count: 0, quality: quality)
            modelContext.insert(PersonCluster(
                clusterID: clusterID, sum: ClipMath.encodeHalf(seeded.sum), count: seeded.count,
                name: nil, coverFaceID: nil))
        }
    }

    func rename(clusterID: Int, name: String?) {
        guard let c = cluster(clusterID) else { return }
        c.name = (name?.isEmpty == true) ? nil : name
        try? modelContext.save()
    }

    /// 人物クラスタ src を dst に統合する（同一人物が 2 クラスタに割れたときの修正）。
    /// src の顔を全て dst へ付け替え、重心（sum/count）を合流し、src のクラスタ行を削除する。
    /// 名前・代表顔は dst を優先し、dst が未設定のときだけ src から引き継ぐ。
    /// 別々の名前が付いているか（どちらも命名済みで名前が違う）。
    /// ユーザーが「この 2 人は別人」と既に表明している状態なので、統合も提案もしない。
    static func namesConflict(_ a: String?, _ b: String?) -> Bool {
        guard let a, !a.isEmpty, let b, !b.isEmpty else { return false }
        return a != b
    }

    // MARK: - クラスタの分割（ADR-69）

    /// クラスタから指定の顔を抜き出して**新しい人物**にする（事後監査の「別人だった」回答）。
    /// 抜いた側は負例として記録し、再クラスタで元に戻らないようにする。
    /// 戻り値: 新しいクラスタ ID（分割できなければ nil）。
    @discardableResult
    func splitCluster(clusterID: Int, faceIDs: [String]) -> Int? {
        let moving = faces(inCluster: clusterID).filter { faceIDs.contains($0.faceID) }
        guard !moving.isEmpty, let src = cluster(clusterID),
              let srcSum = ClipMath.decodeHalf(src.sum) else { return nil }
        let newID = nextClusterID()
        for f in moving {
            guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            // 「この顔はこのクラスタではない」＝負例（1 対 1 の確認なので確度は高い）。
            let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                         FaceClustering.normalized(srcSum))
            recordCorrection(kind: "reassign", faceEmbedding: f.embedding,
                             wrongEmbedding: ClipMath.encodeHalf(srcSum), similarity: sim,
                             confidence: .high)
            removeFromCluster(clusterID: clusterID, vec: vec, quality: Float(f.quality),
                              faceID: f.faceID)
            addToCluster(clusterID: newID, vec: vec, quality: Float(f.quality), faceID: f.faceID)
            f.clusterID = newID
        }
        try? modelContext.save()
        clusteringCache = nil
        Self.log.info("faces: split cluster \(clusterID) → \(newID) (faces=\(moving.count))")
        return newID
    }

    /// 事後監査に「同じ人です」と答えられたら記録し、二度と尋ねない（ADR-69）。
    /// 正例としてしきい値校正にも効く。
    func confirmSameGroup(clusterID: Int, groupBFaceIDs: [String]) {
        let members = faces(inCluster: clusterID)
        let bSet = Set(groupBFaceIDs)
        let vecs = members.compactMap { f -> (v: [Float], isB: Bool)? in
            guard let v = ClipMath.decodeHalf(f.embedding) else { return nil }
            return (FaceClustering.normalized(v), bSet.contains(f.faceID))
        }
        let a = FaceClusterAudit.centroid(vecs.filter { !$0.isB }.map(\.v))
        let b = FaceClusterAudit.centroid(vecs.filter { $0.isB }.map(\.v))
        guard !a.isEmpty, !b.isEmpty else { return }
        let sim = FaceClustering.dot(a, b)
        recordCorrection(kind: "sameGroup", faceEmbedding: ClipMath.encodeHalf(a),
                         wrongEmbedding: ClipMath.encodeHalf(b), similarity: sim,
                         confidence: .high)
        try? modelContext.save()
    }

    // MARK: - 同一写真違反の修復（ADR-68 追補5）

    /// 「1 枚の写真に同じ人物が 2 回」を解消する。誤統合の痕跡なので、
    /// **最良の 1 顔だけ残して他を人物から外し、外した顔は負例として学習させる**
    /// （同じ誤りが再クラスタで再発しないようにする）。
    /// 戻り値: 修復した顔の数。
    @discardableResult
    func repairSamePhotoViolations() -> Int {
        var byPhotoCluster: [String: [DetectedFace]] = [:]
        for f in (try? modelContext.fetch(FetchDescriptor<DetectedFace>())) ?? []
        where f.clusterID >= 0 {
            byPhotoCluster["\(f.refKey)|\(f.clusterID)", default: []].append(f)
        }
        var repaired = 0
        for (_, group) in byPhotoCluster where group.count >= 2 {
            // 残すのは代表選択と同じ基準（品質＋笑顔＋大きさ）で最良の 1 顔。
            guard let keep = Self.bestCoverFace(group) else { continue }
            let clusterSum = cluster(group[0].clusterID).flatMap { ClipMath.decodeHalf($0.sum) }
            for f in group where f.faceID != keep.faceID {
                // 「この顔はこのクラスタではない」を負例として記録（ADR-45）。
                if let vec = ClipMath.decodeHalf(f.embedding), let cSum = clusterSum {
                    let sim = FaceClustering.dot(FaceClustering.normalized(vec),
                                                 FaceClustering.normalized(cSum))
                    recordCorrection(kind: "reassign", faceEmbedding: f.embedding,
                                     wrongEmbedding: ClipMath.encodeHalf(cSum), similarity: sim)
                    // ⚠️ 重心からも寄与を除く。外すだけだと sum/count に抜いた顔が残り、
                    // 夜間の再クラスタまで重心が汚れたままになる（reassignFace と同じ規則）。
                    removeFromCluster(clusterID: f.clusterID, vec: vec,
                                      quality: Float(f.quality), faceID: f.faceID)
                }
                f.clusterID = FaceClustering.unassigned
                repaired += 1
            }
        }
        if repaired > 0 {
            try? modelContext.save()
            clusteringCache = nil
            Self.log.info("faces: repaired same-photo violations — faces=\(repaired)")
        }
        return repaired
    }

    /// 統合を拒否した理由（ADR-68 追補5）。統合は取り消せないので、**間違いの可能性が高い形**は
    /// 実行地点で止める。候補から外すだけでは手動統合（人物画面の「統合」）を防げない。
    enum MergeRejection: String, Sendable {
        /// 別々の名前が付いた人物どうし。ユーザーが「別人」と宣言済みなので統合は誤りの可能性が高い。
        case differentNames
        /// 同じ写真に一緒に写っている＝統合すると「1 枚に同じ人物が 2 回」になる。
        /// 同一人物は 1 枚に 1 回しか写れないので、この対は別人（または重複検出）。
        case samePhotoConflict
    }

    /// 2 クラスタを統合する。**間違いの可能性が高い場合は拒否**して理由を返す（nil = 成功）。
    @discardableResult
    func mergeClusters(from srcID: Int, into dstID: Int,
                      confidence: AnswerConfidence = .high) -> MergeRejection? {
        guard srcID != dstID, let src = cluster(srcID), let dst = cluster(dstID) else { return nil }

        // ガード1: 別々の名前が付いている＝ユーザーが既に「別人」と表明している。
        if let sn = src.name, !sn.isEmpty, let dn = dst.name, !dn.isEmpty, sn != dn {
            Self.log.info("faces: merge rejected — different names (\(sn) / \(dn))")
            return .differentNames
        }

        // ガード2: 同じ写真に一緒に写っているなら統合しない。**別人として学習する**
        //（この対は今後、候補にも自動合流にも出さない）。
        let srcPhotos = Set(faces(inCluster: srcID).map(\.refKey))
        let dstPhotos = Set(faces(inCluster: dstID).map(\.refKey))
        if !srcPhotos.isDisjoint(with: dstPhotos) {
            Self.log.info("faces: merge rejected — same-photo conflict (\(srcID) / \(dstID))")
            markNotSamePerson(clusterA: srcID, clusterB: dstID)
            return .samePhotoConflict
        }
        mergeClustersUnchecked(src: src, dst: dst, confidence: confidence)
        return nil
    }

    /// テスト用: ガードを迂回して統合する（旧ビルドで生じた違反状態の再現に使う）。
    func forceMergeForTesting(from srcID: Int, into dstID: Int) {
        guard let src = cluster(srcID), let dst = cluster(dstID) else { return }
        mergeClustersUnchecked(src: src, dst: dst)
    }

    private func mergeClustersUnchecked(src: PersonCluster, dst: PersonCluster,
                                        confidence: AnswerConfidence = .high) {
        let srcID = src.clusterID, dstID = dst.clusterID
        // ADR-45/46: 統合（＝同一人物）を正例として記録。類似度は**統合前**の重心同士で測る
        //（統合後の dst.sum には src が混ざり、値が不当に高くなるため）。
        if let sSum = ClipMath.decodeHalf(src.sum), let dSumBefore = ClipMath.decodeHalf(dst.sum) {
            let sim = FaceClustering.dot(FaceClustering.normalized(sSum),
                                         FaceClustering.normalized(dSumBefore))
            recordCorrection(kind: "merge", faceEmbedding: ClipMath.encodeHalf(sSum),
                             wrongEmbedding: nil, similarity: sim, confidence: confidence)
        }
        // 顔を一括付け替え（DetectedFace.clusterID）。
        for f in faces(inCluster: srcID) { f.clusterID = dstID }
        // 重心（生合計と件数）を合流。
        if let sSum = ClipMath.decodeHalf(src.sum), let dSum = ClipMath.decodeHalf(dst.sum) {
            let merged = FaceClustering.merging(sumA: dSum, countA: dst.count,
                                                sumB: sSum, countB: src.count)
            dst.sum = ClipMath.encodeHalf(merged.sum)
            dst.count = merged.count
        } else {
            dst.count += src.count
        }
        if (dst.name?.isEmpty ?? true), let n = src.name, !n.isEmpty { dst.name = n }
        if dst.coverFaceID == nil { dst.coverFaceID = src.coverFaceID }
        modelContext.delete(src)
        try? modelContext.save()
        clusteringCache = nil   // 重心が変わったのでインメモリ状態を捨てる（次スキャンで再構築）
    }

}
