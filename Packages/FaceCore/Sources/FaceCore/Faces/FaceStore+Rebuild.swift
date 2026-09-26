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
        // ⚠️ **既に上で全顔を読んでいる**（`allFaces`）。クラスタごとに引き直すと、
        // 人物数ぶんの往復が丸ごと無駄になる（1,316 人なら 1,316 回）。しかも再クラスタは
        // 単一の `@ModelActor` を占有するので、その間はピープル画面・写真の人物名が待たされる。
        // 束ね直しはメモリで行う（挙動は変わらない・ADR-119）。
        var facesByCluster: [Int: [DetectedFace]] = [:]
        for f in allFaces where f.clusterID >= 0 {
            facesByCluster[f.clusterID, default: []].append(f)
        }
        let faceByID = Dictionary(allFaces.map { ($0.faceID, $0) }, uniquingKeysWith: { a, _ in a })
        // ⚠️ **名前付き人物が痩せたら記録する**（ADR-144）。実フィードバック「ピープルアルバムの
        // 写真の全数が減っている気がする」。再クラスタの前後で名前付き人物の枚数を突き合わせる。
        let namedBefore = Self.namedPhotoCounts(existing, facesByCluster: facesByCluster)
        // ⚠️ **表明の国勢調査を前後で取る**（ADR-233）。ここは「消えてはいけないものが消える」
        // 不具合が最も出る場所で、しかも定常状態では走らない（夜だけ）。誰も見ていない時間に
        // 壊れても記録が残るようにする。
        let censusBefore = assertionCensus()

        // ⚠️ **作り直す前に、今の記録が壊れていないかを見る**（ADR-210）。全顔はもう手元に
        // あるので追加の読み出しは要らない。ここで出しておかないと、このあと重心を作り直した
        // 時点でずれが消えてしまい、**壊れていたことに誰も気づけないまま**毎晩直り続ける。
        reportCentroidDrift(existing: existing, facesByCluster: facesByCluster)

        // 1) 種（名前・確認・代表写真・束ね＝ユーザーが表明した人物）を作り直す。
        let built = buildSeeds(existing: existing, facesByCluster: facesByCluster,
                               faceByID: faceByID, negatives: negatives)
        // 2) 残りの顔を平均連結でまとめる（ADR-217）→ 3) 写りの悪い顔を所属だけ付ける（ADR-66）。
        var state = assignByAgglomeration(allFaces: allFaces, faceByID: faceByID, built: built,
                                          negatives: negatives, threshold: thr,
                                          maxExistingID: existing.map(\.clusterID).max() ?? -1)
        assignSecondPass(&state)

        // 4) 書き戻し: 顔の clusterID（確認顔は種のまま）・種以外の旧クラスタ行は削除して再作成。
        let moved = writeBack(allFaces, pinned: built.pinned, state: state)
        // ⚠️ 無名の集合は**削除より前に**作る（レビュー指摘）。削除後に `existing` の
        // `name` / `clusterID` を読むと、消した `PersonCluster` のプロパティを触ることになる。
        var unnamedBeforeDelete = Set(existing.filter { $0.name?.isEmpty ?? true }.map(\.clusterID))
        unnamedBeforeDelete.formUnion(
            Set(state.clustering.clusters.map(\.id)).subtracting(existing.map(\.clusterID)))
        let seedIDs = Set(built.seeds.map(\.id))
        for c in existing where !seedIDs.contains(c.clusterID) {
            modelContext.delete(c)
        }
        persist(state.clustering)

        // 5) 名前は「人」に付いている（ADR-130）。
        followNames(built.anchorlessNamed, assignment: state.assignment,
                    unnamed: unnamedBeforeDelete)

        // 6) 各人物の散らばりを測っておく（ADR-210）。事後監査を尋ねる順番と判定の内訳に使う。
        recordClusterSpreads(faces: allFaces, contributed: state.contributed)
        reportLinkSources()

        try? modelContext.save()
        clusteringCache = nil
        reportNamedShrink(before: namedBefore)
        reportAssertionCensus("rebuild", before: censusBefore)
        Self.log.info("faces: rebuild — clusters=\(state.clustering.clusters.count) moved=\(moved) "
                      + "thr=\(thr)")
        return (state.clustering.clusters.count, moved)
    }

    /// 再クラスタの途中の割り当て（段から段へ受け渡す）。
    struct RebuildAssignment {
        /// 品質の降順に並べた、種に固定されていない顔。
        var pending: [DetectedFace]
        /// まとめ上がった人物の器（第2パスと書き戻しに使う）。
        var clustering: FaceClustering
        var assignment: [String: Int]
        /// **実際に重心へ足した顔**（ADR-210）。
        var contributed: Set<String>
        var linkSource: [String: FaceLinkSource]
        /// 同一写真 cannot-link（写真 → その写真で既に使った人物）。
        var usedByPhoto: [String: Set<Int>]
    }

    /// 名前付き人物ごとの写真の枚数（再クラスタの前後比較・ADR-144）。
    static func namedPhotoCounts(_ clusters: [PersonCluster],
                                 facesByCluster: [Int: [DetectedFace]]) -> [Int: (name: String, photos: Int)] {
        var out: [Int: (name: String, photos: Int)] = [:]
        for c in clusters {
            guard let name = c.name, !name.isEmpty else { continue }
            out[c.clusterID] = (name, Set((facesByCluster[c.clusterID] ?? []).map(\.refKey)).count)
        }
        return out
    }

    /// 1) 種クラスタ（命名済み・確認顔・代表写真・束ね）: アンカーから重心を作り直す。
    ///
    /// ⚠️⚠️ **人物の同一性は、ユーザーが表明したものを最優先で守る**（ADR-130）。
    /// 実フィードバック: 「自分の顔のアルバムが、いつの間にか丸ごと娘の顔になっていた。
    /// 自分の写真は People 9 として追い出されていた」。原因は種の作り方が弱かったこと:
    /// (a) **代表写真（cover）をアンカーにしていなかった**。まとめて確認だけで育てた人物は
    ///     `confirmedAt` を 1 つも持たないので、種は「現重心を 1 票」だけになる。
    /// (b) その **count=1** で、確立した人物が再クラスタの瞬間だけ新参扱いされた。
    /// (c) 重心自体が別人へ引きずられていると、そのまま別人のアルバムになる。
    /// 規則は `FaceSeedBuilder`（純・テスト対象・ADR-198）にある。ここは値の受け渡しだけ。
    /// ⚠️ 埋め込みは**クロージャで 1 枚ずつ**復号する。全顔の `[Float]` を値にすると
    ///    86k × 512 次元 × 4 バイト ≒ 176MB を一度に確保することになる（ADR-6/119/122）。
    private func buildSeeds(existing: [PersonCluster], facesByCluster: [Int: [DetectedFace]],
                            faceByID: [String: DetectedFace],
                            negatives: [FaceClustering.NegativePair]) -> FaceSeedBuilder.Result {
        func ref(_ f: DetectedFace) -> FaceSeedBuilder.FaceRef {
            .init(faceID: f.faceID, quality: Float(f.quality), confirmedAt: f.confirmedAt)
        }
        // ⚠️ **グループのメンバーも種にする**（ADR-231）。グループは clusterID で人物を指すので、
        // 種にしないと再クラスタで行が消え、家族グループからその人が黙って消える。
        // 全グループを 1 回だけ読んで集合にする（人物ごとに引き直さない・ADR-119）。
        let groupMembers = peopleGroupMemberClusterIDs()
        let clusterRefs = existing.map { c in
            FaceSeedBuilder.ClusterRef(
                clusterID: c.clusterID, name: c.name, coverFaceID: c.coverFaceID,
                hasPersonGroup: c.personGroupID != nil,
                inPeopleGroup: groupMembers.contains(c.clusterID),
                members: (facesByCluster[c.clusterID] ?? []).map(ref))
        }
        let storedCentroids = Dictionary(uniqueKeysWithValues:
            existing.map { ($0.clusterID, ClipMath.decodeHalf($0.sum)) })
        return FaceSeedBuilder.build(
            clusters: clusterRefs,
            coverFace: { faceByID[$0].map(ref) },
            embedding: { faceByID[$0].flatMap { ClipMath.decodeHalf($0.embedding) } },
            storedCentroid: { storedCentroids[$0] ?? nil },
            negatives: negatives,
            tuning: tuning,
            qualityFloor: seedQualityFloor,
            maxSeedPrototypes: Self.maxSeedPrototypes)
    }

    /// 2) 残りの顔を**平均連結**でまとめる（ADR-217）。
    ///
    /// 以前は品質降順に 1 枚ずつ最寄りの山へ入れる逐次方式で、山に顔が入るたびに重心が動き
    /// 「混入が次の混入を呼ぶ」形だった（ADR-130）。ここでは「山の全員と全員の類似の平均」で
    /// いちばん近い組から順にまとめる（face-accuracy.md 2026-09-22）。
    /// ⚠️ 種は `FaceSeedBuilder` が固定したまま山として参加し、種どうしはまとめない（ADR-153）。
    /// 同じ写真・負例の拒否も守る。
    /// ⚠️ 校正後のしきい値はここでは使わない——平均連結の線はプロファイルの値
    /// （`tuning.agglomeration`）。校正は昼の逐次割り当て（`recordScan`）と第2パスの器に効く。
    private func assignByAgglomeration(allFaces: [DetectedFace], faceByID: [String: DetectedFace],
                                       built: FaceSeedBuilder.Result,
                                       negatives: [FaceClustering.NegativePair],
                                       threshold: Float, maxExistingID: Int) -> RebuildAssignment {
        let pinned = built.pinned
        let pending = allFaces.filter { pinned[$0.faceID] == nil }
            .sorted { $0.quality != $1.quality ? $0.quality > $1.quality : $0.faceID < $1.faceID }
        // 同一写真 cannot-link（recordScan と同じ制約を全体再割り当てにも）。
        // 確認顔は種クラスタに残るため、その写真×クラスタの占有を先に登録する。
        var usedByPhoto: [String: Set<Int>] = [:]
        var seedPhotos: [Int: Set<String>] = [:]
        var seedMembers: [Int: [String]] = [:]
        for f in allFaces {
            guard let cid = pinned[f.faceID] else { continue }
            usedByPhoto[f.refKey, default: []].insert(cid)
            seedPhotos[cid, default: []].insert(f.refKey)
            if built.contributed.contains(f.faceID) { seedMembers[cid, default: []].append(f.faceID) }
        }
        // ⚠️ 埋め込みは**1 枚ずつ**復号する（86k × 512 次元を一度に持たない・ADR-119/122）。
        func decode(_ faceID: String) -> [Float]? {
            faceByID[faceID].flatMap { ClipMath.decodeHalf($0.embedding) }
        }
        let started = Date()
        let groups = FaceAgglomeration.cluster(
            // ⚠️ 平均連結へ入れる線は `inclusionFloor`（0.10・ADR-220）。昼の品質フロア（0.40）で
            // 切ると、実機では実アルバムの顔の 6 割がここに入れなかった。
            faces: pending.filter { Float($0.quality) >= tuning.agglomeration.inclusionFloor }
                .map { .init(faceID: $0.faceID, photo: $0.refKey) },
            seeds: built.seeds.map { seed in
                .init(clusterID: seed.id, memberFaceIDs: seedMembers[seed.id] ?? [],
                      photos: seedPhotos[seed.id] ?? [], fallbackCentroid: seed.centroid)
            },
            embedding: decode,
            // 撮影日は赤ちゃんの時期の決まり（ADR-219・いまは無効）にだけ使う。
            captureDate: { faceByID[$0]?.captureDate },
            config: tuning.agglomeration,
            blocked: FaceAgglomeration.negativeBlocker(
                negatives: negatives, sameThreshold: tuning.negativeSameThreshold))
        // 実機で所要を確かめる材料（device-verification.md の E1）。
        Diagnostics.mark("faces: agglomeration — 顔 \(pending.count) → 人物 \(groups.count)"
                         + "（種 \(built.seeds.count)）\(Int(Date().timeIntervalSince(started) * 1000))ms")
        let nextID = max(maxExistingID, clusterIDHighWater()) + 1
        let materialized = FaceAgglomeration.materialize(
            groups, seeds: built.seeds, nextID: nextID, embedding: decode,
            quality: { Float(faceByID[$0]?.quality ?? 1) })
        // 第2パス用に、まとめ上がった人物を逐次の器へ載せる（書き戻しもこの器から行う）。
        let clustering = FaceClusteringSetup.make(
            threshold: threshold, qualityFloor: Self.qualityFloor, tuning: tuning,
            seeds: materialized.clusters,
            minimumNextID: max(nextID, (materialized.clusters.map(\.id).max() ?? -1) + 1),
            anchoredClusterIDs: Set(built.seeds.filter { !$0.prototypes.isEmpty }.map(\.id)))
        // ⚠️ **実際に重心へ足した顔**だけを集める（ADR-210）。平均連結で山に入った顔は、
        // 全員が（品質で重み付けして）和に入っている。
        let contributed = built.contributed.union(materialized.assignment.keys)
        var linkSource: [String: FaceLinkSource] = [:]
        for faceID in contributed { linkSource[faceID] = .face }
        for (faceID, clusterID) in materialized.assignment {
            guard let face = faceByID[faceID] else { continue }
            usedByPhoto[face.refKey, default: []].insert(clusterID)
        }
        return RebuildAssignment(pending: pending, clustering: clustering,
                                 assignment: materialized.assignment, contributed: contributed,
                                 linkSource: linkSource, usedByPhoto: usedByPhoto)
    }

    /// 3) 第2パス（ADR-66・recall 回復）: 平均連結に入れなかった顔（`inclusionFloor` 未満＝極端に
    /// 写りの悪い顔）を、**重心を汚さず**最寄り人物へ membership だけ割り当てる（sum/count 不変）。
    /// 「人が写っているのに People に出ない」を減らす。線はプロファイルの `secondPassThreshold`。
    ///
    /// ⚠️ 連写（ADR-211）・服装（ADR-212）による拾い直しはこの後ろにあったが、PIPA の計測で
    /// 繋いだ顔の正解率 0%・B-Cubed F1 低下と分かり撤回した（face-accuracy.md の PIPA 節）。
    private func assignSecondPass(_ state: inout RebuildAssignment) {
        for f in state.pending where (state.assignment[f.faceID] ?? FaceClustering.unassigned) < 0
            && Float(f.quality) < tuning.agglomeration.inclusionFloor {
            guard let vec = ClipMath.decodeHalf(f.embedding) else { continue }
            let cid = state.clustering.assignMembershipOnly(
                faceID: f.faceID, embedding: vec,
                excludedClusterIDs: state.usedByPhoto[f.refKey] ?? [],
                threshold: tuning.secondPassThreshold)
            if cid >= 0 {
                state.assignment[f.faceID] = cid
                state.usedByPhoto[f.refKey, default: []].insert(cid)
                state.linkSource[f.faceID] = .secondPass
            }
        }
    }

    /// 4) 顔の行へ書き戻す。- Returns: 人物が変わった顔の数。
    private func writeBack(_ allFaces: [DetectedFace], pinned: [String: Int],
                           state: RebuildAssignment) -> Int {
        var moved = 0
        for f in allFaces {
            let newID = pinned[f.faceID] ?? (state.assignment[f.faceID] ?? FaceClustering.unassigned)
            if f.clusterID != newID { moved += 1 }
            f.clusterID = newID
            // ⚠️⚠️ **事実を写すだけ**（ADR-210）。以前はここで「留めた顔はすべて寄与した」と
            // 品質を無視して書いており、種の計算（フロア以上だけ足す）と食い違っていた。
            // 実ライブラリでは顔の約半数がフロア未満なので、`count` が実体の数分の 1 になり、
            // 数枚外しただけでクラスタが消える状態になっていた。
            f.contributesToCentroid = newID >= 0 && state.contributed.contains(f.faceID)
            f.linkSource = newID >= 0 ? (state.linkSource[f.faceID] ?? .face).rawValue : nil
            // 撤回した服装の埋め込み（ADR-212）が残っていれば空けて容量を返す。列は台帳の
            // 互換のため残す（ADR-186: 台帳は列を消さない）。
            if f.torsoEmbedding != nil { f.torsoEmbedding = nil }
        }
        return moved
    }

    /// 5) **名前は「人」に付いている**（ADR-130）。アンカーの無い命名済み人物の顔が
    /// まるごと別クラスタへ移ったのに、名前だけ元の ID に残ると——そこへ流れ込んだ
    /// 別人が、その名前のアルバムとして表示される（実害: 「私」のアルバムが娘の写真に
    /// なり、自分の顔は "People 9" として追い出されていた）。過半が移った先が無名なら、
    /// 名前をそちらへ移す。判断は `FaceNameFollowing.moves`（純・テスト対象・ADR-198）。
    /// ⚠️ **1 つ移すたびに行き先を「名前あり」に落とす**（レビュー指摘）。集合を固定したまま
    /// 回すと、2 人の無名命名済みが同じクラスタへ合流したとき 1 人目の名前が上書きされて消える。
    private func followNames(_ anchorlessNamed: [FaceNameFollowing.Candidate],
                             assignment: [String: Int], unnamed: Set<Int>) {
        var available = unnamed
        for move in FaceNameFollowing.moves(candidates: anchorlessNamed, assignment: assignment,
                                            isUnnamed: { available.contains($0) }) {
            guard available.contains(move.to), let dst = cluster(move.to) else { continue }
            cluster(move.from)?.name = nil
            dst.name = move.name
            available.remove(move.to)
            Self.log.info("faces: rebuild — name '\(move.name)' followed its members \(move.from)→\(move.to)")
        }
    }

    /// 全消去（再スキャン用）。
    /// ⚠️ 修正ジャーナル（FaceCorrection）は**消さない**（ADR-45）。負例は埋め込みキーなので、
    /// 再スキャン中の割り当てで自動的に再適用され、既知の誤りが再発しない。
    // MARK: - スキャン版数移行（表明の持ち越し＝名前・束ね・グループ所属・ADR-51/232）

    /// ユーザーが表明した人物のスナップショット（版上げ再スキャンの前に取得）。
    /// メンバー refKey は照合に十分な数（既定 500）に丸める。
    ///
    /// ⚠️ **名前だけではない**（ADR-232）。束ね（`personGroupID`）とピープルグループの所属も
    /// 同じ重みの表明なので一緒に持ち越す。無名でもそれらがあれば対象にする
    /// ——以前は `name` が空の行を弾いていたため、無名のまま家族グループに入れた人物が
    /// 再スキャンで**グループから黙って消えて**いた。
    func assertedClusterEntries(maxMembers: Int = 500) -> [CarriedAssertion] {
        var out: [CarriedAssertion] = []
        // ⚠️ クラスタごとに引かない（ADR-119）。必要なのは refKey だけなので射影 1 回で取る。
        let refKeysByCluster = memberRefKeysByCluster()
        // グループの所属も 1 回だけ読む（clusterID → 属する group の id）。
        var groupsByCluster: [Int: [UUID]] = [:]
        for record in (countedFetchOptional(FetchDescriptor<PeopleGroupRecord>())) ?? [] {
            for clusterID in record.memberClusterIDs {
                groupsByCluster[clusterID, default: []].append(record.id)
            }
        }
        for c in allClusters() {
            let entry = CarriedAssertion(
                name: c.name, personGroupID: c.personGroupID,
                peopleGroupIDs: groupsByCluster[c.clusterID] ?? [],
                memberRefKeys: Array((refKeysByCluster[c.clusterID] ?? []).prefix(maxMembers)))
            guard entry.isAsserted else { continue }
            out.append(entry)
        }
        return out
    }

    /// 再スキャン後の**表明の再適用**（名前・束ね・グループ所属・ADR-51/169/232）。
    /// 旧クラスタのメンバー写真（refKey）との重なりが最大の新クラスタへ戻す
    /// （写真は再スキャンしても変わらない＝安定キー）。
    /// 一致条件: 重なり ≥ max(2, 旧メンバーの 20%)。スキャンが数晩に分かれても、
    /// 条件を満たした分から段階的に戻る。戻り値は**未適用の残り**（次回セッションで再試行）。
    func reapplyAssertions(_ entries: [CarriedAssertion]) -> [CarriedAssertion] {
        guard !entries.isEmpty else { return [] }

        // ⚠️ **同名クラスタがあることを理由にエントリを捨てない**（ADR-169）。
        // 「太郎」が 2 人いるのは普通で、捨てると 2 人目の名前と旧メンバーの対応が
        // **永久に失われる**（残りにも積まれないので再試行もされない）。
        // 既に表明を持つクラスタは「割り当て先の候補から外す」だけにする
        // ——エントリ自体は必ず生き残らせ、対応先が無ければ残りとして返す。
        // ⚠️ 見るのは名前だけではない（ADR-232）。前の晩に束ね／グループ所属だけを
        // 戻した行を候補に残すと、別のエントリがその行を**上書き**してしまう。
        let groupMembers = peopleGroupMemberClusterIDs()
        // ⚠️ `allClusters()` は**1 回だけ**引く（この下の札の割り当てでも要る・ADR-119）。
        let clusters = allClusters()
        let claimed = Set(clusters.filter {
            $0.name?.isEmpty == false || $0.personGroupID != nil
                || groupMembers.contains($0.clusterID)
        }.map(\.clusterID))

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
            for f in rows where !claimed.contains(f.clusterID) {
                overlap[f.clusterID, default: []].insert(f.refKey)
            }
            let need = max(2, entry.memberRefKeys.count / 5)
            let viable = overlap.compactMapValues { $0.count >= need ? $0.count : nil }
            candidates.append(.init(name: entry.name ?? "", candidates: viable))
        }

        // ⚠️ **一対一で解く**（貪欲だと、局所的な最良ペアが別エントリ唯一の対応先を奪う）。
        let (assignments, unmatched) = NameCarryoverMatching.match(candidates)
        // 束ねの札を割り当てる（ADR-232）。**いま台帳に在る札を見て空きを取る**ので、
        // 旧世代の番号と新しい束ねの番号がぶつからない。負の札は持ち越し済みなのでそのまま。
        let bundleTags = CarriedAssertion.carriedBundleTags(
            for: entries.compactMap(\.personGroupID),
            usedTags: Set(clusters.compactMap(\.personGroupID)))
        // グループ id → この回に決まった新クラスタ ID（あとでメンバーを書き直す）。
        var restoredGroupMembers: [UUID: [Int]] = [:]
        for (index, clusterID) in assignments {
            guard let c = cluster(clusterID) else { continue }
            let entry = entries[index]
            if let name = entry.name, !name.isEmpty, c.name?.isEmpty ?? true { c.name = name }
            if let old = entry.personGroupID, c.personGroupID == nil {
                c.personGroupID = bundleTags[old] ?? old
            }
            for groupID in entry.peopleGroupIDs {
                restoredGroupMembers[groupID, default: []].append(clusterID)
            }
        }
        remapPeopleGroupMembers(restored: restoredGroupMembers, live: Set(clusters.map(\.clusterID)))
        try? modelContext.save()
        if !unmatched.isEmpty {
            Self.log.info("faces: carryover — \(assignments.count) 件を再適用 / "
                          + "\(unmatched.count) 件は対応先未確定（次回へ持ち越し）")
        }
        // 対応先が決まらなかったものは**必ず**残りとして返す（次のスキャンで再評価）。
        // ⚠️ **割り当てた札を書き戻して返す**。書き戻さないと、次の晩にもう一度
        // 「空いている札」を取りに行って**別の札**になり、同じ子の時期クラスタが 2 人に割れる。
        return unmatched.map { index in
            var entry = entries[index]
            if let old = entry.personGroupID, let tag = bundleTags[old] { entry.personGroupID = tag }
            return entry
        }
    }

    /// ピープルグループのメンバーを新しい clusterID に書き直す（ADR-232）。
    ///
    /// ⚠️ **足すだけにする**（既に生きている ID は残す）。再スキャンは数晩に分かれるので、
    /// この回に戻せたのはメンバーの一部でしかない。毎回上書きすると前の晩に戻した人が消える。
    /// 生きていない ID（旧世代の残骸）は落とす——落としても、対応するエントリは
    /// 「残り」として持ち越しに積まれたままなので、後の晩に新しい ID で戻ってくる。
    /// - Parameter live: いま在るクラスタ ID（呼び出し側が既に引いた集合を渡す・ADR-119）。
    private func remapPeopleGroupMembers(restored: [UUID: [Int]], live: Set<Int>) {
        guard !restored.isEmpty else { return }
        for record in (countedFetchOptional(FetchDescriptor<PeopleGroupRecord>())) ?? [] {
            guard let added = restored[record.id] else { continue }
            var seen = Set<Int>()
            let members = (record.memberClusterIDs.filter { live.contains($0) } + added)
                .filter { seen.insert($0).inserted }
            if members != record.memberClusterIDs {
                record.memberClusterIDs = members
                invalidatePeopleGroupMembersCache()
            }
        }
    }

    func reset() {
        try? modelContext.delete(model: DetectedFace.self)
        try? modelContext.delete(model: PersonCluster.self)
        try? modelContext.delete(model: ScannedPhoto.self)
        // ⚠️ **グループのメンバーを空にする**（ADR-232）。メンバーは clusterID なので、
        // ここで意味を失う（ID は 0 から振り直される）。残すと、再スキャンで同じ番号を
        // 割り当てられた**別人**が家族グループに居座る——「消える」より悪い。
        // 空にして、持ち越し（`reapplyAssertions`）に写真の重なりで入れ直させる。
        // グループの行そのものは消さない（id・名前はユーザーが付けたもの）。
        for record in (try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>())) ?? [] {
            record.memberClusterIDs = []
        }
        try? modelContext.save()
        invalidatePeopleGroupMembersCache()
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
