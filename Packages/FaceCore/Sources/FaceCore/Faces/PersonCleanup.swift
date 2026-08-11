import PerceptionCore
import CoreGraphics
import Foundation

/// 「この人物を整理」（ADR-111）: 複数の別人が混ざった人物を**グループ単位で一括分離**する。
///
/// 動機（実フィードバック）: 混入クラスタ・誤った束ねで 1 人物に多数の別人が含まれると、
/// 1 対 1 のレビュー（「同じ人物ですか？」）では回数が多すぎて追いつかない。中身を自動で
/// サブグループ化して見せ、「別人」のグループにチェック → 一括分離、を 1 画面で行う。
///
/// サブグループの作り方:
/// - 束ねた人物（personGroupID）: 構成クラスタがそのまま候補（分離＝束ねから外す）。
/// - 各クラスタの内部: 事後監査（`FaceClusterAudit`）の 2 分割を**再帰適用**して
///   「互いに離れた塊」を切り出す（分離＝クラスタ分割＋負例学習）。
public struct PersonSubgroup: Sendable, Identifiable, Equatable {
    public let id: String
    public let clusterID: Int
    /// クラスタ内の一部を切り出す場合の顔 ID 群。nil ＝クラスタ丸ごと（束ね内の 1 クラスタ）。
    public let faceIDs: [String]?
    /// このサブグループの写真数（refKey の重複排除後）。
    public let photoCount: Int
    /// 代表顔（品質＋笑顔＋大きさで選ぶ・アバター表示用）。
    public let coverFace: PersonInfo.Face?
    /// このサブグループが属するクラスタに付いている名前（表示用・nil なら未命名）。
    public let clusterName: String?
    public var isWholeCluster: Bool { faceIDs == nil }
}

extension FaceClusterAudit {
    /// 2 分割監査を**再帰適用**して k 群に分ける（ADR-111）。
    /// 各群が `config.minMembers` 未満になるか、監査が「1 つの連続した帯」と判定したら止まる。
    /// 戻り値は入力添字の分割（写真数の代わりに要素数の大きい順・分割なしなら全体 1 群）。
    public static func recursiveSplit(embeddings: [[Float]], photoKeys: [String] = [],
                                      config: Config = Config(), maxGroups: Int = 6) -> [[Int]] {
        func divide(_ indices: [Int], budget: Int) -> [[Int]] {
            guard budget > 1, indices.count >= config.minMembers else { return [indices] }
            let subEmbeddings = indices.map { embeddings[$0] }
            let subKeys = photoKeys.isEmpty ? [] : indices.map { photoKeys[$0] }
            guard let s = auditForSplit(embeddings: subEmbeddings, photoKeys: subKeys,
                                        config: config) else { return [indices] }
            let a = s.groupA.map { indices[$0] }
            let b = s.groupB.map { indices[$0] }
            // 大きい側により多くの分割予算を割り当てる（多人数が均等に混ざる形に対応）。
            let left = divide(a, budget: budget - 1)
            let right = divide(b, budget: budget - left.count)
            return left + right
        }
        guard !embeddings.isEmpty else { return [] }
        return divide(Array(embeddings.indices), budget: maxGroups)
            .sorted { $0.count > $1.count }
    }
}

extension FaceStore {
    /// 「この人物を整理」画面の材料（束ね内クラスタ × クラスタ内の再帰分割）。
    func cleanupSubgroups(primaryClusterID: Int) -> [PersonSubgroup] {
        var out: [PersonSubgroup] = []
        for cid in linkedClusterIDs(primary: primaryClusterID) {
            let name = cluster(cid)?.name
            let members = faces(inCluster: cid)
            var vectors: [[Float]] = []
            var kept: [DetectedFace] = []
            var keys: [String] = []
            for f in members {
                guard let v = ClipMath.decodeHalf(f.embedding) else { continue }
                vectors.append(v); kept.append(f); keys.append(f.refKey)
            }
            let parts = FaceClusterAudit.recursiveSplit(embeddings: vectors, photoKeys: keys,
                                                        config: tuning.auditConfig)
            func face(_ f: DetectedFace?) -> PersonInfo.Face? {
                f.map { PersonInfo.Face(faceID: $0.faceID, refKey: $0.refKey,
                                        boundingBox: CGRect(x: $0.bx, y: $0.by,
                                                            width: $0.bw, height: $0.bh)) }
            }
            if parts.count <= 1 {
                out.append(PersonSubgroup(id: "c\(cid)", clusterID: cid, faceIDs: nil,
                                          photoCount: Set(members.map(\.refKey)).count,
                                          coverFace: face(Self.bestCoverFace(members)),
                                          clusterName: name))
            } else {
                for (i, part) in parts.enumerated() {
                    let group = part.map { kept[$0] }
                    out.append(PersonSubgroup(id: "c\(cid)-\(i)", clusterID: cid,
                                              faceIDs: group.map(\.faceID),
                                              photoCount: Set(group.map(\.refKey)).count,
                                              coverFace: face(Self.bestCoverFace(group)),
                                              clusterName: name))
                }
            }
        }
        return out.sorted { $0.photoCount > $1.photoCount }
    }
}

extension PeopleEngine {
    /// 「この人物を整理」画面の材料。写真数の大きい順（先頭＝残す側の既定）。
    public func cleanupSubgroups(for person: PersonInfo) async -> [PersonSubgroup] {
        await store.cleanupSubgroups(primaryClusterID: person.clusterID)
    }

    /// 選択したサブグループを**別の人物として一括分離**する。
    /// - クラスタ丸ごと（束ね内の 1 クラスタ）→ 束ねから外す（そのクラスタ単独の人物に戻る）。
    /// - クラスタ内の一部 → クラスタ分割（新しい人物 ID・**負例として学習**＝再クラスタで
    ///   元に戻らない。`FaceStore.splitCluster` と同じ経路＝事後監査の「別人」回答と同等）。
    public func separateSubgroups(_ selected: [PersonSubgroup]) async {
        for group in selected {
            if let faceIDs = group.faceIDs {
                await store.splitCluster(clusterID: group.clusterID, faceIDs: faceIDs)
            } else {
                await store.unlinkCluster(group.clusterID)
            }
        }
        await loadPeople()
    }
}
