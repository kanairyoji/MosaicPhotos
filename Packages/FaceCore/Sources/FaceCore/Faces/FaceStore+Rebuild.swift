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
    /// 種クラスタに載せる代表（プロトタイプ＝「見本」）の上限。
    ///
    /// ⚠️⚠️ **見本は増やすほど悪くなる**（ADR-151・FG-NET 実測）。アンカーを見本として
    /// 類似判定に使うと、純度が k=1 で 0.877→0.812、k=5 で **0.509** まで落ちた
    /// （純度 0.8 未満の人物が 17→49 人）。見本が「別人への橋」になるため。
    /// 一方、アンカーを**種にする（先に置いて固定する）**だけなら悪化しない（0.877→0.87）。
    /// ADR-130/132 の目的（同一性の固定）は種とピン留めで達成できるので、見本は 1 枚に絞る。
    /// 1 顔ごとに全クラスタ×全見本と内積を取るコスト（ADR-119）の面でも軽い。
    static let maxSeedPrototypes = 1


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
        // ⚠️ **名前付き人物が痩せたら記録する**（ADR-144）。実フィードバック「ピープルアルバムの
        // 写真の全数が減っている気がする」。感覚を裏取りできるよう、再クラスタの前後で
        // 名前付き人物の枚数を突き合わせ、減った分だけ診断ログに出す。
        var namedBefore: [Int: (name: String, photos: Int)] = [:]
        for c in existing {
            guard let name = c.name, !name.isEmpty else { continue }
            let photos = Set((facesByCluster[c.clusterID] ?? []).map(\.refKey)).count
            namedBefore[c.clusterID] = (name, photos)
        }
        for c in existing {
            let members = facesByCluster[c.clusterID] ?? []
            // 代表写真の顔は、いま別クラスタへ流れていても**この人物のアンカー**として扱う
            // （追い出されたあとでも、ユーザーの表明で引き戻せるようにする）。
            let coverFace = c.coverFaceID.flatMap { faceByID[$0] }
            var anchors = members.filter { $0.confirmedAt != nil }
            if let coverFace, !anchors.contains(where: { $0.faceID == coverFace.faceID }) {
                anchors.append(coverFace)
            }
            // ⚠️ **束ね（personGroupID）もユーザーの表明**（ADR-134）。種にしないと、この行は
            // 再クラスタで削除され（下の「種以外は削除」）、**束ねが黙って消える**——
            // 「何度も束ねているのに忘れる」の正体はこれ。
            let isSeed = (c.name?.isEmpty == false) || !anchors.isEmpty || c.personGroupID != nil
            guard isSeed else { continue }
            // アンカーは**代表顔を先頭**に、確認の新しい順から上限まで（`prototypes` は 1 顔ごとに
            // 全候補と内積を取るので、増やしすぎると再クラスタが人数×アンカー数で重くなる）。
            let orderedAnchors = ([coverFace].compactMap { $0 }
                + anchors.filter { $0.faceID != coverFace?.faceID }
                    .sorted { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) })
                .prefix(Self.maxSeedPrototypes)
            var sum: [Float] = []
            var count = 0
            var protos: [[Float]] = []
            for a in orderedAnchors {
                guard let vec = ClipMath.decodeHalf(a.embedding) else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: vec.count) }
                protos.append(FaceClustering.normalized(vec))
            }
            let anchorCentroid = protos.first.map { first -> [Float] in
                var acc = first
                for p in protos.dropFirst() {
                    for i in acc.indices where i < p.count { acc[i] += p[i] }
                }
                return FaceClustering.normalized(acc)
            }

            // ⚠️⚠️ **ユーザーが表明した人物（名前 or 代表写真 or 確認顔）のメンバーは、
            // 機械の都合で外に出さない**（ADR-132）。実フィードバック:
            // 「すでに名前の付いているアルバムは、よほどのことが無い限り 2 つに分けたり、
            //   構成するグループを切り分けたりは不要。そういうケースは一人ずつ確認する画面に
            //   出して、ユーザーが『この人ではない』と指摘して初めて分割を検討すればよい」。
            // 以前は**メンバー全員を毎晩プールへ戻して割り当て直していた**ので、しきい値・
            // マージン・別クラスタの成長といった機械の都合だけで、名前を付けたアルバムの中身が
            // 毎晩入れ替わり得た。今は既存メンバーはその人物に留め、外れるのは
            // **ユーザーの指摘（負例）に一致した顔だけ**にする。
            var pinnedMembers: [DetectedFace] = []
            for m in members {
                guard let vec = ClipMath.decodeHalf(m.embedding) else { continue }
                // ユーザーが「この人ではない」と外した顔と同一人物なら、留めない
                // （同じ誤りの再発を防ぐ・ADR-45 の負例エグゼンプラ）。
                //
                // ⚠️⚠️ **既にこの人物に入っている顔を、負例で一斉に外さない**（ADR-140）。
                // 実フィードバック: 「診断画面で数枚を『この人ではない』にしたら、その人物の
                // アルバムが激減した」。負例の「同一人物」線（arcface 0.45）は**本人の顔どうしの
                // 類似度より低い**ので、外した 1 枚が本人に似ていると**アルバムのほぼ全員が
                // その負例に一致**して一斉に外れる（実測 12 枚→3 枚）。
                // ここで外すのは「外したその顔と実質同じ顔」（連写・重複検出）だけにする。
                // 混入は**ユーザーが 1 枚ずつ外す**——そのための入口は増やした（ADR-133/137）。
                // 新しく入ろうとする顔の拒否（`assign` 側）は相対判定で従来どおり効く。
                let normalized = FaceClustering.normalized(vec)
                let isAnchor = m.confirmedAt != nil || m.faceID == c.coverFaceID
                if !isAnchor, let anchorCentroid,
                   let matched = FaceClustering.firstNegativeMatch(
                       normalized, centroid: anchorCentroid, negatives: negatives,
                       sameThreshold: tuning.negativeSameThreshold),
                   FaceClustering.dot(normalized, matched.faceCentroid)
                       >= FaceClustering.negativeDuplicateThreshold {
                    continue
                }
                pinnedMembers.append(m)
                pinnedCluster[m.faceID] = c.clusterID
                // 重心は**留めたメンバーの加重平均**（＝再クラスタ前と同じ向き）。アンカーは
                // 上の `prototypes` として別に効くので、重心が薄まっても本人は引き当てられる。
                guard FaceStore.contributesToCentroid(m) else { continue }
                if sum.isEmpty || sum.allSatisfy({ $0 == 0 }) {
                    sum = [Float](repeating: 0, count: vec.count)
                    count = 0
                }
                let added = FaceClustering.adding(vec, toSum: sum, count: count,
                                                  quality: Float(m.quality))
                sum = added.sum
                count = added.count
            }
            if sum.isEmpty || count == 0 {
                // 留めるメンバーが 1 人も居ない（全員がユーザー指摘で外れた等）。
                // 向きだけ現重心 or アンカーから維持する。
                guard let fallback = anchorCentroid ?? ClipMath.decodeHalf(c.sum) else { continue }
                sum = FaceClustering.normalized(fallback)
                count = max(1, count)
            }
            seeds.append(FaceClustering.Cluster(
                id: c.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: count, faceIDs: [], prototypes: protos))
            seedIDs.insert(c.clusterID)
            // アンカーが 1 つも無い命名済み人物は、同一性の後ろ盾が重心の向きだけ。
            // 顔が大きく入れ替わったときに名前を人の側へ持っていけるよう、旧メンバーを控える
            // （下の 3.5）。アンカーがある人物は種が動かないので対象外。
            if protos.isEmpty, let name = c.name, !name.isEmpty {
                anchorlessNamed.append((c.clusterID, name, pinnedMembers.map(\.faceID)))
            }
        }

        // 2) 残りの顔を品質降順に割り当て（新規クラスタ ID は既存の最大より先から）。
        var clustering = FaceClustering(threshold: thr, qualityFloor: Self.qualityFloor,
                                        seedClusters: seeds, minimumNextID: maxExistingID + 1)
        // 確立した人物は校正の引き上げ分を免除する（ADR-141）。種は上でアンカーから作っている。
        clustering.baseThreshold = tuning.clusterThreshold
        clustering.anchoredClusterIDs = Set(seeds.filter { !$0.prototypes.isEmpty }.map(\.id))
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
        reportNamedShrink(before: namedBefore)
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
        guard !entries.isEmpty else { return [] }

        // ⚠️ **同名クラスタがあることを理由にエントリを捨てない**（ADR-169）。
        // 「太郎」が 2 人いるのは普通で、捨てると 2 人目の名前と旧メンバーの対応が
        // **永久に失われる**（残りにも積まれないので再試行もされない）。
        // 既に名前が付いているクラスタは「割り当て先の候補から外す」だけにする
        // ——エントリ自体は必ず生き残らせ、対応先が無ければ残りとして返す。
        let named = Set(allClusters().filter { $0.name?.isEmpty == false }.map(\.clusterID))

        // 各エントリの候補（新クラスタ → 重なり枚数）を作る。足切りは従来どおり
        // 「重なり ≥ max(2, 旧メンバーの 20%)」。
        var candidates: [NameCarryoverMatching.Entry] = []
        for entry in entries {
            let keys = entry.memberRefKeys
            var d = FetchDescriptor<DetectedFace>(
                predicate: #Predicate { keys.contains($0.refKey) && $0.clusterID >= 0 })
            d.propertiesToFetch = [\.clusterID, \.refKey]
            let rows = (countedFetchOptional(d)) ?? []
            var overlap: [Int: Set<String>] = [:]
            for f in rows where !named.contains(f.clusterID) {
                overlap[f.clusterID, default: []].insert(f.refKey)
            }
            let need = max(2, entry.memberRefKeys.count / 5)
            let viable = overlap.compactMapValues { $0.count >= need ? $0.count : nil }
            candidates.append(.init(name: entry.name, candidates: viable))
        }

        // ⚠️ **一対一で解く**（貪欲だと、局所的な最良ペアが別エントリ唯一の対応先を奪う）。
        let (assignments, unmatched) = NameCarryoverMatching.match(candidates)
        for (index, clusterID) in assignments {
            guard let c = cluster(clusterID), c.name?.isEmpty ?? true else { continue }
            c.name = entries[index].name
        }
        try? modelContext.save()
        if !unmatched.isEmpty {
            Self.log.info("faces: carryover — \(assignments.count) 件を再適用 / "
                          + "\(unmatched.count) 件は対応先未確定（次回へ持ち越し）")
        }
        // 対応先が決まらなかったものは**必ず**残りとして返す（次のスキャンで再評価）。
        return unmatched.map { entries[$0] }
    }

    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        try? modelContext.save()
        clusteringCache = nil
        negativesCache = nil   // 次スキャンで DB から読み直す（ジャーナルは残存）
        calibrationSamplesCache = nil
        thresholdCache = nil
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

extension FaceStore {

    /// 再クラスタで**名前付き人物が痩せていないか**を突き合わせる（ADR-144）。
    ///
    /// ⚠️ ユーザーが育てたアルバムが縮むのは、原因が何であれ**知らせるべき事象**。
    /// 「気のせいかもしれない」を次回は数字で確かめられるようにする。台帳は変更しない。
    /// 判定は純粋な突き合わせなので、結果を返してテストで確かめられるようにする。
    func namedShrinkReport(before: [Int: (name: String, photos: Int)])
        -> (totalBefore: Int, totalAfter: Int, shrunk: [(name: String, from: Int, to: Int)])? {
        guard !before.isEmpty else { return nil }
        let refKeysByCluster = memberRefKeysByCluster()
        var shrunk: [(name: String, from: Int, to: Int)] = []
        var totalBefore = 0, totalAfter = 0
        for (clusterID, entry) in before {
            let after = refKeysByCluster[clusterID]?.count ?? 0
            totalBefore += entry.photos
            totalAfter += after
            // 5 枚以上・2 割以上減った人物だけ挙げる（端数の出入りは日常）。
            if entry.photos >= 5, after < entry.photos * 4 / 5 {
                shrunk.append((entry.name, entry.photos, after))
            }
        }
        guard totalAfter != totalBefore || !shrunk.isEmpty else { return nil }
        return (totalBefore, totalAfter, shrunk.sorted { ($0.from - $0.to) > ($1.from - $1.to) })
    }

    /// 上の突き合わせを診断ログへ出す。
    func reportNamedShrink(before: [Int: (name: String, photos: Int)]) {
        guard let report = namedShrinkReport(before: before) else { return }
        let worst = report.shrunk.prefix(5)
            .map { "\($0.name) \($0.from)→\($0.to)" }.joined(separator: ", ")
        Diagnostics.mark("faces: named photos \(report.totalBefore)→\(report.totalAfter) "
                         + "(shrunk=\(report.shrunk.count)\(worst.isEmpty ? "" : ": " + worst))")
    }
}
