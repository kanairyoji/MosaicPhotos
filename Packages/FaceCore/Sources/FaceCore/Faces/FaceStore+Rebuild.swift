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
        // ⚠️ 顔が 0 件でも**素通りしない**。クラスタ行だけが残ると、その sum/count は
        // 既に消えた顔の寄与を抱えたままで、次のスキャンで二重計上される。
        // 顔もクラスタも無いときだけ何もしない。
        if allFaces.isEmpty && allClusters().isEmpty { return (0, 0) }
        let thr = calibratedThreshold()
        let negatives = loadNegatives()
        let existing = allClusters()
        let maxExistingID = existing.map(\.clusterID).max() ?? -1
        // ⚠️ **既に上で全顔を読んでいる**（`allFaces`）。クラスタごとに引き直すと、
        // 人物数ぶんの往復が丸ごと無駄になる（1,316 人なら 1,316 回）。しかも再クラスタは
        // 単一の `@ModelActor` を占有するので、その間はピープル画面・写真の人物名が待たされる。
        // 束ね直しはメモリで行う（挙動は変わらない・ADR-119）。
        var facesByCluster: [Int: [DetectedFace]] = [:]
        for f in allFaces where f.clusterID >= 0 {
            facesByCluster[f.clusterID, default: []].append(f)
        }

        // 1) 種クラスタ（命名済み or 確認顔あり）: アンカーだけから重心を作り直す。
        //
        // ⚠️⚠️ **人物の同一性は、ユーザーが表明したものを最優先で守る**（ADR-130）。
        // 実フィードバック: 「自分の顔のアルバムが、いつの間にか丸ごと娘の顔になっていた。
        // 自分の写真は People 9 として追い出されていた」。原因は種の作り方が弱かったこと:
        // (a) **代表写真（cover）をアンカーにしていなかった**。1 対 1 の確認をしていない人物
        //     （まとめて確認だけで育てた人物）は `confirmedAt` を 1 つも持たないので、
        //     種は「現重心を 1 票」だけになる。
        // (b) その **count=1** が致命的で、サイズ適応マージン（ADR-58）は小さいクラスタほど
        //     合流を厳しくする——**1,000 枚の確立した人物が、再クラスタの瞬間だけ
        //     「生まれたての 1 顔クラスタ」として扱われる**。本人の顔すら入れなくなる。
        // (c) 重心自体が別人へ引きずられていると、そのまま別人のアルバムになる。
        // 対処: **代表写真をアンカーに含める**（ユーザーが「この人はこの顔」と選んだ表明）。
        // さらに種の `count` は**以前の規模を引き継ぐ**（確立した人物を作り直しの瞬間に
        // 新参扱いしない）。
        let faceByID = Dictionary(allFaces.map { ($0.faceID, $0) }, uniquingKeysWith: { a, _ in a })
        var seeds: [FaceClustering.Cluster] = []
        var seedIDs = Set<Int>()
        var anchorlessNamed: [(clusterID: Int, name: String, faceIDs: [String])] = []
        // 確認顔（アンカー）は再割り当てせず**その人物に固定**する。値は固定先のクラスタ ID
        // ——代表写真の顔が既に別クラスタへ流れている場合は、ここで引き戻す。
        var pinnedCluster: [String: Int] = [:]
        for c in existing {
            let members = facesByCluster[c.clusterID] ?? []
            // 代表写真の顔は、いま別クラスタへ流れていても**この人物のアンカー**として扱う
            // （追い出されたあとでも、ユーザーの表明で引き戻せるようにする）。
            let coverFace = c.coverFaceID.flatMap { faceByID[$0] }
            var anchors = members.filter { $0.confirmedAt != nil }
            if let coverFace, !anchors.contains(where: { $0.faceID == coverFace.faceID }) {
                anchors.append(coverFace)
            }
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
                pinnedCluster[a.faceID] = c.clusterID
            }
            if sum.isEmpty {
                guard let cur = ClipMath.decodeHalf(c.sum) else { continue }
                sum = FaceClustering.normalized(cur)   // 現重心（方向のみ維持）
            }
            // ⚠️ **成熟度を引き継ぐ**。ここを票数（アンカー数）のままにすると、確立した人物が
            // 作り直しの瞬間だけ「小さいクラスタ」になり、サイズ適応マージンで本人の顔が
            // 入れなくなる（＝別人に乗っ取られる）。重心の向きはアンカーが決め、
            // 大きさ（＝どれだけ動きにくいか）は以前の規模が決める。
            count = max(count, members.filter { FaceStore.contributesToCentroid($0) }.count)
            seeds.append(FaceClustering.Cluster(
                id: c.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: count, faceIDs: [], prototypes: protos))
            seedIDs.insert(c.clusterID)
            // アンカーが 1 つも無い命名済み人物は、同一性の後ろ盾が重心の向きだけ。
            // 顔が大きく入れ替わったときに名前を人の側へ持っていけるよう、旧メンバーを控える
            // （下の 3.5）。アンカーがある人物は種が動かないので対象外。
            if protos.isEmpty, let name = c.name, !name.isEmpty {
                anchorlessNamed.append((c.clusterID, name, members.map(\.faceID)))
            }
        }

        // 2) 残りの顔を品質降順に割り当て（新規クラスタ ID は既存の最大より先から）。
        var clustering = FaceClustering(threshold: thr, qualityFloor: Self.qualityFloor,
                                        seedClusters: seeds, minimumNextID: maxExistingID + 1)
        clustering.assignMargin = tuning.assignMargin   // マージンゲート（ADR-57）
        clustering.sizeAdaptiveMarginMax = tuning.sizeAdaptiveMarginMax   // サイズ適応（ADR-58）
        clustering.negativeSameThreshold = tuning.negativeSameThreshold
        // サイズ適応マージンの免除（ADR-68・少人数ライブラリ限定）
        // マージンゲートの免除（ADR-126・校正で bar が上がっているときだけ）。
        clustering.rivalAwareMarginGate = Self.rivalAwareMarginGateWhenCalibratedUp
            && clustering.threshold > tuning.clusterThreshold
        clustering.rivalAwareSizeMargin = Self.rivalAwareSizeMargin
        clustering.rivalAwareSizeMarginMaxPeople = Self.rivalAwareSizeMarginMaxPeople
        clustering.rivalAlikeMargin = tuning.rivalAlikeMargin
        // 実効しきい値の頭打ち（ADR-68 追補・少人数ライブラリ限定）。しきい値は校正で
        // 上がり得るので、そこへサイズ加算が乗って跳ね上がるのを止める。
        if Self.capEffectiveThresholdWhenFewPeople {
            clustering.effectiveThresholdCap = clustering.threshold
            clustering.effectiveThresholdCapMaxPeople = Self.effectiveThresholdCapMaxPeople
        }
        let pending = allFaces.filter { pinnedCluster[$0.faceID] == nil }
            .sorted { $0.quality > $1.quality }
        // 同一写真 cannot-link（recordScan と同じ制約を全体再割り当てにも）。
        // 確認顔は種クラスタに残るため、その写真×クラスタの占有を先に登録する。
        var usedByPhoto: [String: Set<Int>] = [:]
        for f in allFaces {
            guard let pinned = pinnedCluster[f.faceID] else { continue }
            usedByPhoto[f.refKey, default: []].insert(pinned)
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
            let newID = pinnedCluster[f.faceID]
                ?? (newAssignment[f.faceID] ?? FaceClustering.unassigned)
            if f.clusterID != newID { moved += 1 }
            f.clusterID = newID
            // 重心に寄与したかを更新する。第2パスで入れた顔（品質フロア未満）は
            // membership だけなので false（付け替え時に引いてはいけない）。
            f.contributesToCentroid = newID >= 0
                && (pinnedCluster[f.faceID] != nil || Float(f.quality) >= Self.qualityFloor)
        }
        for c in existing where !seedIDs.contains(c.clusterID) {
            modelContext.delete(c)
        }
        persist(clustering)

        // 3.5) **名前は「人」に付いている**（ADR-130）。アンカーの無い命名済み人物の顔が
        // まるごと別クラスタへ移ったのに、名前だけ元の ID に残ると——そこへ流れ込んだ
        // 別人が、その名前のアルバムとして表示される（実害: 「私」のアルバムが娘の写真に
        // なり、自分の顔は "People 9" として追い出されていた）。過半が移った先が無名なら、
        // 名前をそちらへ移す。
        for entry in anchorlessNamed where !entry.faceIDs.isEmpty {
            var landing: [Int: Int] = [:]
            for fid in entry.faceIDs {
                let cid = newAssignment[fid] ?? FaceClustering.unassigned
                if cid >= 0 { landing[cid, default: 0] += 1 }
            }
            let kept = landing[entry.clusterID] ?? 0
            guard kept * 2 < entry.faceIDs.count,
                  let best = landing.max(by: { $0.value < $1.value }),
                  best.key != entry.clusterID, best.value * 2 >= entry.faceIDs.count,
                  let dst = cluster(best.key), dst.name?.isEmpty ?? true else { continue }
            cluster(entry.clusterID)?.name = nil
            dst.name = entry.name
            Self.log.info("faces: rebuild — name '\(entry.name)' followed its members \(entry.clusterID)→\(best.key)")
        }

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
        // ⚠️ クラスタごとに引かない（ADR-119）。必要なのは refKey だけなので射影 1 回で取る。
        let refKeysByCluster = memberRefKeysByCluster()
        for c in allClusters() {
            guard let name = c.name, !name.isEmpty else { continue }
            let keys = Array(refKeysByCluster[c.clusterID] ?? [])
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

    /// **クラウド分だけ**スキャン結果を捨てる（ADR-90）。
    ///
    /// 顔解析の取得解像度を 256px → 1024px に上げ、顔ピクセル下限を 48 → 80 に変えたので、
    /// クラウド写真は測り直す必要がある。一方**ローカルは元から 1024px で処理済み**なので
    /// 捨てる理由がない。全再スキャン（`reset()`）だと 17,953 枚のローカルまで無駄になるため、
    /// refKey の接頭辞（"C-"）で選択的に消す。クラスタは残し、再スキャンで合流させる
    /// （命名も残るので持ち越し処理が不要）。
    /// - Returns: 破棄したスキャン済みマーカーの件数。
    func resetCloudScans() -> Int {
        let cloudFaces = (try? modelContext.fetch(FetchDescriptor<DetectedFace>(
            predicate: #Predicate { $0.refKey.starts(with: "C-") }))) ?? []
        for face in cloudFaces { modelContext.delete(face) }
        let cloudMarkers = (try? modelContext.fetch(FetchDescriptor<ScannedPhoto>(
            predicate: #Predicate { $0.refKey.starts(with: "C-") }))) ?? []
        for marker in cloudMarkers { modelContext.delete(marker) }
        try? modelContext.save()
        // ⚠️ **クラスタを組み直す**。顔を消しただけでは `PersonCluster.sum/count` に
        // 消した顔の寄与が残り、次スキャンでその古い重心へクラウド顔が再加算されて
        // **重心と件数が二重化**する。キャッシュを捨てるだけでは足りない——次回は
        // 残った PersonCluster 行から復元されるため（レビュー指摘）。
        // 残存する顔だけから作り直す（命名・確認顔は種として保持されるので持ち越しは不変）。
        // 併せて、メンバーが居なくなったクラウド専用クラスタ（幽霊）もここで消える。
        let rebuilt = rebuildClusters()
        Self.log.info("faces: resetCloudScans — dropped \(cloudFaces.count) cloud face(s), "
            + "rebuilt \(rebuilt.clusters) cluster(s)")
        negativesCache = nil
        return cloudMarkers.count
    }

    /// 修正ジャーナルも含めた完全消去（Developer Options の「学習もリセット」用）。
    func resetIncludingCorrections() {
        try? modelContext.delete(model: FaceCorrection.self)
        reset()
    }
}
