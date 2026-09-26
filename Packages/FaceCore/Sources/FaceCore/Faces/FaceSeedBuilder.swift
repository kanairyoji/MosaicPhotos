import Foundation
import PerceptionCore

/// **種クラスタの構築**（ADR-130/132/140/141 の規則・純ロジック・テスト対象・ADR-198）。
///
/// ## なぜ出したか
/// この判断は `rebuildClusters()`（254 行・分岐 61）の中にあり、`@Model` を直接いじりながら
/// 進むので**単独で呼べなかった**。ここに書かれている規則は、どれも実フィードバックで踏んだ
/// 実害への対処で、**壊れたときの症状が重い**:
/// - ADR-130「自分の顔のアルバムが、いつの間にか丸ごと娘の顔になっていた」
/// - ADR-132「名前を付けたアルバムの中身が毎晩入れ替わる」
/// - ADR-140「診断画面で数枚を『この人ではない』にしたら、その人物のアルバムが激減した」
/// - ADR-141「確立した人物が、再クラスタの瞬間だけ生まれたての 1 顔クラスタとして扱われる」
/// - ADR-231「家族グループに入れた人が、夜のあいだにグループから消える」
///
/// ## 埋め込みはクロージャで 1 枚ずつ取り出す
/// ⚠️ 全顔の `[Float]` を値型にして渡すと、86k 件 × 512 次元 × 4 バイト ≒ **176MB** を
/// 一度に確保することになる（ADR-6/119/122 が繰り返し扱ってきた形）。メタデータだけを値で渡し、
/// 埋め込みは `embedding(faceID)` で必要なときに 1 枚ずつ復号する——メモリの挙動は元のままで、
/// テストは辞書を渡すだけで書ける。
public enum FaceSeedBuilder {

    /// 顔の**軽い**メタデータ（埋め込みは含まない）。
    public struct FaceRef: Sendable, Equatable {
        public let faceID: String
        public let quality: Float
        /// ユーザーが「この人だ」と確認した時刻。新しい順にアンカーとして使う。
        public let confirmedAt: Date?

        public init(faceID: String, quality: Float, confirmedAt: Date? = nil) {
            self.faceID = faceID
            self.quality = quality
            self.confirmedAt = confirmedAt
        }

        var isAnchorByConfirmation: Bool { confirmedAt != nil }

        /// 重心（sum/count）の材料にしてよい顔か。
        ///
        /// ⚠️⚠️ **行に記録された `contributesToCentroid` を見ない**（ADR-210）。
        /// 以前はそれを優先して読んでいたため、判断が**自分の過去の記録を参照する**形になり、
        /// 一度ずれた記録が毎晩そのまま受け継がれた（しかも書き戻し側は別の規則で書いていた）。
        /// 再クラスタは重心を**作り直す**のだから、材料の選び方は最初の割り当てと同じ
        /// 「品質フロア以上か」だけで決める——そして決めた結果を事実として書き戻す。
        func contributes(qualityFloor: Float) -> Bool { quality >= qualityFloor }
    }

    /// クラスタの**軽い**メタデータ。
    public struct ClusterRef: Sendable, Equatable {
        public let clusterID: Int
        public let name: String?
        public let coverFaceID: String?
        /// 束ね（`personGroupID`）があるか。**束ねもユーザーの表明**なので種にする（ADR-134）
        /// ——種にしないと再クラスタで行が削除され、束ねが黙って消える。
        public let hasPersonGroup: Bool
        /// ピープルグループ（家族・チーム）のメンバーとして指名されているか。
        ///
        /// ⚠️ **グループに入れる行為も、名前を付けるのと同じ表明**（ADR-134 の範囲を広げた
        /// ＝ADR-231）。グループは clusterID で人物を指しているので、種にしないと再クラスタで
        /// その行が消え、**家族グループからその人が黙って消える**（`PeopleGroupInfo.resolve` が
        /// 現存しないメンバーを落とす）。無名でもグループに入っていれば種にする。
        public let inPeopleGroup: Bool
        public let members: [FaceRef]

        public init(clusterID: Int, name: String? = nil, coverFaceID: String? = nil,
                    hasPersonGroup: Bool = false, inPeopleGroup: Bool = false,
                    members: [FaceRef] = []) {
            self.clusterID = clusterID
            self.name = name
            self.coverFaceID = coverFaceID
            self.hasPersonGroup = hasPersonGroup
            self.inPeopleGroup = inPeopleGroup
            self.members = members
        }

        var isNamed: Bool { name?.isEmpty == false }

        /// ユーザーが何かを表明した人物か（＝行を消してはいけない人物）。
        /// アンカー（確認顔・代表写真）は呼び出し側が別に見る。
        var isAsserted: Bool { isNamed || hasPersonGroup || inPeopleGroup }
    }

    public struct Result: Sendable {
        /// 作り直した種クラスタ。
        public var seeds: [FaceClustering.Cluster] = []
        /// この人物に**固定**する顔（faceID → clusterID）。再割り当ての対象から外れる。
        public var pinned: [String: Int] = [:]
        /// アンカーの無い命名済み人物（顔がまるごと移ったら名前も移す・ADR-130）。
        public var anchorlessNamed: [FaceNameFollowing.Candidate] = []
        /// **実際に `sum`/`count` へ足した顔**（ADR-210）。書き戻しはこれを事実として写す
        /// ——「留めた顔はすべて寄与した」と推し量ってはいけない（実ライブラリでは顔の
        /// 約半数がフロア未満で、`count` が実体の 1/7 になっていた）。
        public var contributed: Set<String> = []
    }

    /// 種を作る。
    ///
    /// - Parameters:
    ///   - coverFace: 代表写真の顔。**いま別クラスタへ流れていても**この人物のアンカーとして扱う
    ///     （追い出されたあとでもユーザーの表明で引き戻せるように・ADR-130）。
    ///   - embedding: faceID → 埋め込み（復号は 1 枚ずつ）。
    ///   - storedCentroid: clusterID → 保存済みの重心（留めるメンバーが 1 人も居ないときの退避先）。
    public static func build(clusters: [ClusterRef],
                             coverFace: (String) -> FaceRef?,
                             embedding: (String) -> [Float]?,
                             storedCentroid: (Int) -> [Float]?,
                             negatives: [FaceClustering.NegativePair],
                             tuning: FaceTuning,
                             qualityFloor: Float,
                             maxSeedPrototypes: Int) -> Result {
        var result = Result()

        for cluster in clusters {
            let cover = cluster.coverFaceID.flatMap { coverFace($0) }
            var anchors = cluster.members.filter(\.isAnchorByConfirmation)
            if let cover, !anchors.contains(where: { $0.faceID == cover.faceID }) {
                anchors.append(cover)
            }
            // 種になるのは「ユーザーが何かを表明した人物」だけ
            //（名前・確認顔・代表写真・束ね・**ピープルグループのメンバー**）。
            guard cluster.isAsserted || !anchors.isEmpty else { continue }

            // アンカーは**代表顔を先頭**に、確認の新しい順から上限まで。
            // ⚠️ 見本（prototypes）は増やすほど悪くなる（ADR-151・FG-NET 実測で純度 0.877→0.509）
            // ——見本が「別人への橋」になるため。上限は 1。
            let orderedAnchors = ([cover].compactMap { $0 }
                + anchors.filter { $0.faceID != cover?.faceID }
                    .sorted { ($0.confirmedAt ?? .distantPast) > ($1.confirmedAt ?? .distantPast) })
                .prefix(maxSeedPrototypes)

            var sum: [Float] = []
            var count = 0
            var prototypes: [[Float]] = []
            for anchor in orderedAnchors {
                guard let vector = embedding(anchor.faceID) else { continue }
                if sum.isEmpty { sum = [Float](repeating: 0, count: vector.count) }
                prototypes.append(FaceClustering.normalized(vector))
            }
            let anchorCentroid = prototypes.first.map { first -> [Float] in
                var accumulated = first
                for p in prototypes.dropFirst() {
                    for i in accumulated.indices where i < p.count { accumulated[i] += p[i] }
                }
                return FaceClustering.normalized(accumulated)
            }

            // ⚠️⚠️ **ユーザーが表明した人物のメンバーは、機械の都合で外に出さない**（ADR-132）。
            // 以前はメンバー全員を毎晩プールへ戻して割り当て直していたので、しきい値・マージン・
            // 別クラスタの成長といった機械の都合だけで、名前を付けたアルバムの中身が毎晩入れ替わり得た。
            var pinnedMembers: [FaceRef] = []
            for member in cluster.members {
                guard let vector = embedding(member.faceID) else { continue }
                let normalized = FaceClustering.normalized(vector)
                let isAnchor = member.isAnchorByConfirmation || member.faceID == cluster.coverFaceID
                // ⚠️⚠️ **既にこの人物に入っている顔を、負例で一斉に外さない**（ADR-140）。
                // 負例の「同一人物」線は本人の顔どうしの類似度より低いので、外した 1 枚が本人に
                // 似ているとアルバムのほぼ全員が一致して一斉に外れる（実測 12 枚→3 枚）。
                // ここで外すのは「外したその顔と実質同じ顔」（連写・重複検出）だけ。
                if !isAnchor, let anchorCentroid,
                   let matched = FaceClustering.firstNegativeMatch(
                       normalized, centroid: anchorCentroid, negatives: negatives,
                       sameThreshold: tuning.negativeSameThreshold),
                   FaceClustering.dot(normalized, matched.faceCentroid)
                       >= FaceClustering.negativeDuplicateThreshold {
                    continue
                }
                pinnedMembers.append(member)
                result.pinned[member.faceID] = cluster.clusterID
                // 重心は**留めたメンバーの加重平均**（＝再クラスタ前と同じ向き）。
                guard member.contributes(qualityFloor: qualityFloor) else { continue }
                result.contributed.insert(member.faceID)
                if sum.isEmpty || sum.allSatisfy({ $0 == 0 }) {
                    sum = [Float](repeating: 0, count: vector.count)
                    count = 0
                }
                let added = FaceClustering.adding(vector, toSum: sum, count: count,
                                                  quality: member.quality)
                sum = added.sum
                count = added.count
            }

            if sum.isEmpty || count == 0 {
                // 留めるメンバーが 1 人も居ない（全員がユーザー指摘で外れた等）。
                // 向きだけ現重心 or アンカーから維持する。
                //
                // ⚠️ **既知の粗さ（挙動は旧実装のまま）**: ここで `continue` すると種が作られない
                // のに、上で `pinned` へ入れた顔は残る。その顔は削除されるクラスタを指したままに
                // なり、起動時の `repairOrphanFaces`（ADR-187）に拾われる。直すと挙動が変わるため
                // ここでは保存し、`unresolved-problems.md` に記録した。
                guard let fallback = anchorCentroid ?? storedCentroid(cluster.clusterID) else {
                    // ⚠️ **孤児を作らずに降りる**（ADR-210）。ここで種を作れないのにピン留めだけ
                    // 残すと、その顔は「これから削除されるクラスタ」を指したまま書き戻され、
                    // 起動時の `repairOrphanFaces` に拾われるまで人物から消える。
                    // 留めるのをやめれば、その顔は普通の再割り当てへ回るだけで済む。
                    for member in pinnedMembers { result.pinned[member.faceID] = nil }
                    for member in pinnedMembers { result.contributed.remove(member.faceID) }
                    continue
                }
                sum = FaceClustering.normalized(fallback)
                count = max(1, count)
            }

            result.seeds.append(FaceClustering.Cluster(
                id: cluster.clusterID, centroid: FaceClustering.normalized(sum),
                sum: sum, count: count, faceIDs: [], prototypes: prototypes))

            // アンカーが 1 つも無い命名済み人物は、同一性の後ろ盾が重心の向きだけ。
            // 顔が大きく入れ替わったときに名前を人の側へ持っていけるよう、旧メンバーを控える。
            if prototypes.isEmpty, let name = cluster.name, !name.isEmpty {
                result.anchorlessNamed.append(.init(clusterID: cluster.clusterID, name: name,
                                                    faceIDs: pinnedMembers.map(\.faceID)))
            }
        }
        return result
    }
}
