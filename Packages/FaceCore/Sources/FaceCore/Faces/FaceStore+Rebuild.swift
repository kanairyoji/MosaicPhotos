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
        // ⚠️ **名前付き人物が痩せたら記録する**（ADR-144）。実フィードバック「ピープルアルバムの
        // 写真の全数が減っている気がする」。感覚を裏取りできるよう、再クラスタの前後で
        // 名前付き人物の枚数を突き合わせ、減った分だけ診断ログに出す。
        var namedBefore: [Int: (name: String, photos: Int)] = [:]
        for c in existing {
            guard let name = c.name, !name.isEmpty else { continue }
            let photos = Set((facesByCluster[c.clusterID] ?? []).map(\.refKey)).count
            namedBefore[c.clusterID] = (name, photos)
        }

        // 種の構築は `FaceSeedBuilder`（純・テスト対象・ADR-198）に出した。ここは値の受け渡しだけ。
        // ⚠️ 埋め込みは**クロージャで 1 枚ずつ**復号する。全顔の `[Float]` を値にすると
        //    86k × 512 次元 × 4 バイト ≒ 176MB を一度に確保することになる（ADR-6/119/122）。
        func ref(_ f: DetectedFace) -> FaceSeedBuilder.FaceRef {
            .init(faceID: f.faceID, quality: Float(f.quality),
                  confirmedAt: f.confirmedAt, contributesToCentroid: f.contributesToCentroid)
        }
        let clusterRefs = existing.map { c in
            FaceSeedBuilder.ClusterRef(
                clusterID: c.clusterID, name: c.name, coverFaceID: c.coverFaceID,
                hasPersonGroup: c.personGroupID != nil,
                members: (facesByCluster[c.clusterID] ?? []).map(ref))
        }
        let storedCentroids = Dictionary(uniqueKeysWithValues:
            existing.map { ($0.clusterID, ClipMath.decodeHalf($0.sum)) })
        let built = FaceSeedBuilder.build(
            clusters: clusterRefs,
            coverFace: { faceByID[$0].map(ref) },
            embedding: { faceByID[$0].flatMap { ClipMath.decodeHalf($0.embedding) } },
            storedCentroid: { storedCentroids[$0] ?? nil },
            negatives: negatives,
            tuning: tuning,
            qualityFloor: Self.qualityFloor,
            maxSeedPrototypes: Self.maxSeedPrototypes)
        let seeds = built.seeds
        let seedIDs = Set(seeds.map { $0.id })
        let pinnedCluster = built.pinned
        let anchorlessNamed = built.anchorlessNamed

        // 2) 残りの顔を品質降順に割り当て（新規クラスタ ID は既存の最大より先から）。
        // ノブの設定は `FaceClusteringSetup`（純・テスト対象）に一元化した（ADR-198）——
        // 以前はスキャン時（`makeClustering`）と**同じ 10 行がここにもコピー**されていた。
        // 種はアンカーから作ってあるので、校正の引き上げ分を免除する対象＝prototypes を持つ種。
        var clustering = FaceClusteringSetup.make(
            threshold: thr, qualityFloor: Self.qualityFloor, tuning: tuning,
            seeds: seeds, minimumNextID: max(maxExistingID, clusterIDHighWater()) + 1,
            anchoredClusterIDs: Set(seeds.filter { !$0.prototypes.isEmpty }.map(\.id)))
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
        // ⚠️ 無名の集合は**削除より前に**作る（レビュー指摘）。削除後に `existing` の
        // `name` / `clusterID` を読むと、消した `PersonCluster` のプロパティを触ることになる。
        var unnamedBeforeDelete = Set(existing.filter { $0.name?.isEmpty ?? true }.map(\.clusterID))
        unnamedBeforeDelete.formUnion(
            Set(clustering.clusters.map(\.id)).subtracting(existing.map(\.clusterID)))

        for c in existing where !seedIDs.contains(c.clusterID) {
            modelContext.delete(c)
        }
        persist(clustering)

        // 3.5) **名前は「人」に付いている**（ADR-130）。アンカーの無い命名済み人物の顔が
        // まるごと別クラスタへ移ったのに、名前だけ元の ID に残ると——そこへ流れ込んだ
        // 別人が、その名前のアルバムとして表示される（実害: 「私」のアルバムが娘の写真に
        // なり、自分の顔は "People 9" として追い出されていた）。過半が移った先が無名なら、
        // 名前をそちらへ移す。
        // 判断は `FaceNameFollowing.moves`（純・テスト対象・ADR-198）。ここは反映だけ。
        // ⚠️ **1 つ移すたびに行き先を「名前あり」に落とす**（レビュー指摘）。旧実装は
        // 行き先の名前を**その場で読み直して**いたので、2 人の無名命名済みが同じクラスタへ
        // 合流したとき 2 人目は見送られた。集合を固定したまま回すと両方が通り、
        // 1 人目の名前が上書きされて**利用者が付けた名前が消える**。
        var available = unnamedBeforeDelete
        for move in FaceNameFollowing.moves(candidates: anchorlessNamed, assignment: newAssignment,
                                            isUnnamed: { available.contains($0) }) {
            guard available.contains(move.to), let dst = cluster(move.to) else { continue }
            cluster(move.from)?.name = nil
            dst.name = move.name
            available.remove(move.to)
            Self.log.info("faces: rebuild — name '\(move.name)' followed its members \(move.from)→\(move.to)")
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
