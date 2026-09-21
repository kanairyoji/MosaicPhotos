import Foundation
import Testing
@testable import FaceCore

/// クラスタリング設定（ADR-198）。以前は同じ 10 行がスキャン時と再クラスタの**2 か所にコピー**
/// されていた。片方にノブを足し忘れると、同じライブラリでも「スキャンで入った顔」と
/// 「再クラスタで入った顔」が別の規則で判定される——誰も気づけない種類のズレになる。
@Suite("クラスタリング設定（ADR-198）")
struct FaceClusteringSetupTests {

    private func make(threshold: Float, tuning: FaceTuning = .arcFace,
                      flags: FaceClusteringSetup.Flags = .production,
                      anchored: Set<Int> = []) -> FaceClustering {
        FaceClusteringSetup.make(threshold: threshold, qualityFloor: 0.4, tuning: tuning,
                                 seeds: [], minimumNextID: 1,
                                 anchoredClusterIDs: anchored, flags: flags)
    }

    /// ノブを 1 つでも落とすとここが落ちる（＝2 か所コピーの再発防止）。
    @Test("同梱モデルの校正値がすべて渡る")
    func everyTuningKnobIsCarriedThrough() {
        let tuning = FaceTuning.arcFace
        let c = make(threshold: tuning.clusterThreshold)
        #expect(c.baseThreshold == tuning.clusterThreshold)
        #expect(c.assignMargin == tuning.assignMargin)
        #expect(c.sizeAdaptiveMarginMax == tuning.sizeAdaptiveMarginMax)
        #expect(c.negativeSameThreshold == tuning.negativeSameThreshold)
        #expect(c.rivalAlikeMargin == tuning.rivalAlikeMargin)
    }

    /// ADR-141: 確立した人物（アンカー持ち）は、ユーザー校正でしきい値が上がっても免除する。
    @Test("アンカー持ちのクラスタは校正の引き上げを免除される")
    func anchoredClustersKeepTheBaseThreshold() {
        let c = make(threshold: 0.5, anchored: [3, 7])
        #expect(c.anchoredClusterIDs == [3, 7])
        #expect(c.baseThreshold == FaceTuning.arcFace.clusterThreshold)
    }

    /// ADR-126: マージンゲートの免除は「校正で bar が上がっているときだけ」。
    @Test("マージンゲートの免除は、校正でしきい値が上がっているときだけ")
    func rivalAwareMarginGateOnlyWhenCalibratedUp() {
        var flags = FaceClusteringSetup.Flags.production
        flags.rivalAwareMarginGateWhenCalibratedUp = true
        let base = FaceTuning.arcFace.clusterThreshold
        #expect(make(threshold: base + 0.05, flags: flags).rivalAwareMarginGate)
        #expect(!make(threshold: base, flags: flags).rivalAwareMarginGate, "上がっていないのに免除した")
        // フラグが off なら、しきい値が上がっていても免除しない。
        #expect(!make(threshold: base + 0.05).rivalAwareMarginGate)
    }

    /// ADR-68 追補: 校正で上がったしきい値へ、さらにサイズ加算が乗って跳ね上がるのを止める。
    @Test("実効しきい値の頭打ちは、フラグが on のときだけ・値はしきい値そのもの")
    func effectiveThresholdCap() {
        let on = make(threshold: 0.42)
        #expect(on.effectiveThresholdCap == 0.42)
        #expect(on.effectiveThresholdCapMaxPeople == 10)

        var flags = FaceClusteringSetup.Flags.production
        flags.capEffectiveThresholdWhenFewPeople = false
        #expect(make(threshold: 0.42, flags: flags).effectiveThresholdCap == 0)
    }

    @Test("本番フラグの値（face-accuracy.md の校正と対）")
    func productionFlags() {
        let f = FaceClusteringSetup.Flags.production
        #expect(!f.rivalAwareMarginGateWhenCalibratedUp)
        #expect(f.rivalAwareSizeMargin)
        #expect(f.rivalAwareSizeMarginMaxPeople == 10)
        #expect(f.capEffectiveThresholdWhenFewPeople)
        #expect(f.effectiveThresholdCapMaxPeople == 10)
    }
}

/// 名前の追随（ADR-130・ADR-198）。
///
/// 実害の記録: 「自分の顔のアルバムが、いつの間にか丸ごと娘の顔になっていた。自分の写真は
/// People 9 として追い出されていた」。アンカーの無い命名済み人物は同一性の後ろ盾が重心の
/// 向きだけなので、顔がまるごと移ったら名前も移す。
@Suite("名前の追随（ADR-130）")
struct FaceNameFollowingTests {

    private func candidate(_ id: Int, _ name: String, _ faces: [String]) -> FaceNameFollowing.Candidate {
        .init(clusterID: id, name: name, faceIDs: faces)
    }

    @Test("過半が別の無名クラスタへ移ったら、名前もそちらへ移す")
    func nameFollowsTheMajority() {
        let moves = FaceNameFollowing.moves(
            candidates: [candidate(1, "私", ["a", "b", "c", "d"])],
            assignment: ["a": 9, "b": 9, "c": 9, "d": 1],
            isUnnamed: { _ in true })
        #expect(moves == [.init(from: 1, to: 9, name: "私")])
    }

    @Test("過半が元に残っていれば移さない")
    func staysWhenTheMajorityRemains() {
        let moves = FaceNameFollowing.moves(
            candidates: [candidate(1, "私", ["a", "b", "c", "d"])],
            assignment: ["a": 1, "b": 1, "c": 9, "d": 9],
            isUnnamed: { _ in true })
        #expect(moves.isEmpty, "半々では移さない（2*2 < 4 が偽）")
    }

    /// 名前のある人物を上書きしない（別人のアルバムに名前を付け替えてしまう）。
    @Test("移った先に名前があれば移さない")
    func doesNotOverwriteANamedCluster() {
        let moves = FaceNameFollowing.moves(
            candidates: [candidate(1, "私", ["a", "b", "c"])],
            assignment: ["a": 9, "b": 9, "c": 9],
            isUnnamed: { $0 != 9 })
        #expect(moves.isEmpty)
    }

    @Test("未割当（負の ID）に流れた顔は数に入れない")
    func unassignedFacesDoNotCount() {
        let moves = FaceNameFollowing.moves(
            candidates: [candidate(1, "私", ["a", "b", "c", "d"])],
            assignment: ["a": FaceClustering.unassigned, "b": FaceClustering.unassigned,
                         "c": 9, "d": 9],
            isUnnamed: { _ in true })
        #expect(moves == [.init(from: 1, to: 9, name: "私")], "未割当 2 を除いた過半で判定する")
    }

    /// ⚠️ 旧実装は `Dictionary.max(by:)` で、**同数のとき結果が実行ごとに変わり得た**
    /// （同じデータで違う人物に名前が移る＝再現できない不具合）。ID の小さい方に固定する。
    @Test("回帰: 同数で並んだときの行き先は決定的（ID の小さい方）")
    func tiesAreDeterministic() {
        for _ in 0..<50 {
            let moves = FaceNameFollowing.moves(
                candidates: [candidate(1, "私", ["a", "b", "c", "d"])],
                assignment: ["a": 8, "b": 8, "c": 9, "d": 9],
                isUnnamed: { _ in true })
            #expect(moves == [.init(from: 1, to: 8, name: "私")], "同数の行き先がぶれている")
        }
    }

    @Test("メンバーが居ない候補は無視する")
    func emptyCandidateIsIgnored() {
        #expect(FaceNameFollowing.moves(candidates: [candidate(1, "私", [])],
                                        assignment: [:], isUnnamed: { _ in true }).isEmpty)
    }
}

/// 種クラスタの構築（ADR-130/132/140/141・ADR-198）。
/// 以前は `rebuildClusters()`（254 行）の中にあり、単独で呼べなかった。
/// ここに書かれている規則は**壊れたときの症状が重い**ので、1 つずつ固定する。
@Suite("種クラスタの構築（ADR-198）")
struct FaceSeedBuilderTests {

    private let dim = 8
    /// 直交に近い、決定的なベクトルを作る。
    private func vector(_ seed: Int) -> [Float] {
        (0..<dim).map { Float(($0 * 7 + seed * 13) % 11) / 11.0 + (($0 == seed % dim) ? 1.0 : 0.0) }
    }
    private func face(_ id: String, quality: Float = 0.8,
                      confirmed: Bool = false) -> FaceSeedBuilder.FaceRef {
        .init(faceID: id, quality: quality, confirmedAt: confirmed ? Date() : nil)
    }
    private func build(_ clusters: [FaceSeedBuilder.ClusterRef],
                       embeddings: [String: [Float]],
                       negatives: [FaceClustering.NegativePair] = [],
                       stored: [Int: [Float]] = [:]) -> FaceSeedBuilder.Result {
        FaceSeedBuilder.build(
            clusters: clusters,
            coverFace: { id in embeddings[id] != nil ? self.face(id) : nil },
            embedding: { embeddings[$0] },
            storedCentroid: { stored[$0] },
            negatives: negatives, tuning: .arcFace, qualityFloor: 0.4, maxSeedPrototypes: 1)
    }

    /// ユーザーが何も表明していない人物は種にしない（機械が作っただけのクラスタは配り直す）。
    @Test("名前も確認顔も代表写真も束ねも無いクラスタは種にならない")
    func plainClusterIsNotASeed() {
        let r = build([.init(clusterID: 1, members: [face("a")])], embeddings: ["a": vector(1)])
        #expect(r.seeds.isEmpty)
        #expect(r.pinned.isEmpty)
    }

    @Test("名前があれば種になり、メンバーはその人物に固定される（ADR-132）")
    func namedClusterPinsItsMembers() {
        let r = build([.init(clusterID: 1, name: "私", members: [face("a"), face("b")])],
                      embeddings: ["a": vector(1), "b": vector(2)])
        #expect(r.seeds.map(\.id) == [1])
        #expect(r.pinned == ["a": 1, "b": 1])
    }

    /// ADR-134: 束ねもユーザーの表明。種にしないと再クラスタで行が消え、束ねが黙って消える。
    @Test("束ね（personGroupID）だけでも種になる")
    func groupedClusterIsASeed() {
        let r = build([.init(clusterID: 5, hasPersonGroup: true, members: [face("a")])],
                      embeddings: ["a": vector(1)])
        #expect(r.seeds.map(\.id) == [5])
    }

    /// ADR-130: 代表写真の顔が別クラスタへ流れていても、この人物のアンカーとして扱う。
    @Test("代表写真の顔は、別クラスタへ流れていてもアンカーになる")
    func coverFaceWorksAsAnAnchorEvenWhenItDrifted() {
        let r = build([.init(clusterID: 1, coverFaceID: "cover", members: [face("a")])],
                      embeddings: ["a": vector(1), "cover": vector(3)])
        #expect(r.seeds.map(\.id) == [1], "代表写真があるので種になる")
        #expect(r.seeds.first?.prototypes.count == 1, "代表顔が見本になる")
    }

    /// ADR-151: 見本は増やすほど悪くなる（FG-NET 実測で純度 0.877→0.509）。上限を守る。
    @Test("見本は上限（1）を超えない")
    func prototypesRespectTheLimit() {
        let members = (0..<5).map { face("c\($0)", confirmed: true) }
        var embeddings: [String: [Float]] = [:]
        for (i, m) in members.enumerated() { embeddings[m.faceID] = vector(i) }
        let r = build([.init(clusterID: 1, name: "私", members: members)], embeddings: embeddings)
        #expect(r.seeds.first?.prototypes.count == 1)
    }

    /// ADR-130: アンカーの無い命名済み人物だけが「名前の追随」の候補になる。
    @Test("アンカーの無い命名済み人物だけが名前追随の候補になる")
    func onlyAnchorlessNamedClustersBecomeFollowCandidates() {
        let anchorless = build([.init(clusterID: 1, name: "私", members: [face("a")])],
                               embeddings: ["a": vector(1)])
        #expect(anchorless.anchorlessNamed.map(\.clusterID) == [1])

        let anchored = build([.init(clusterID: 2, name: "私", members: [face("b", confirmed: true)])],
                             embeddings: ["b": vector(2)])
        #expect(anchored.anchorlessNamed.isEmpty, "アンカーがあれば種が動かないので候補外")
    }

    /// ADR-140 の回帰: 負例で**一斉に**外さない。外れるのは「その顔と実質同じ顔」だけ。
    @Test("回帰: 負例に似ているだけのメンバーは外さない（アルバムが激減しない）")
    func negativesDoNotEvictTheWholeAlbum() {
        let target = vector(1)
        // 負例の「間違えた顔」はメンバーとはっきり違う向きにしておく。
        let negative = FaceClustering.NegativePair(
            faceCentroid: FaceClustering.normalized(vector(6)),
            wrongCentroid: FaceClustering.normalized(vector(7)))
        let members = (0..<6).map { face("m\($0)") }
        var embeddings: [String: [Float]] = [:]
        for m in members { embeddings[m.faceID] = target }
        embeddings["anchor"] = target

        let r = build([.init(clusterID: 1, name: "私", coverFaceID: "anchor", members: members)],
                      embeddings: embeddings, negatives: [negative])
        #expect(r.pinned.count == members.count, "本人の顔が負例で一斉に外れた（ADR-140 の再発）")
    }

    /// 確認顔・代表写真は負例判定の対象外（ユーザーの表明を機械が覆さない）。
    @Test("確認顔は負例で外れない")
    func confirmedFacesAreNeverEvicted() {
        let shared = FaceClustering.normalized(vector(1))
        let negative = FaceClustering.NegativePair(faceCentroid: shared, wrongCentroid: shared)
        let r = build([.init(clusterID: 1, name: "私",
                             members: [face("a", confirmed: true), face("b")])],
                      embeddings: ["a": shared, "b": shared], negatives: [negative])
        #expect(r.pinned["a"] == 1, "確認顔が外れた")
    }

    /// 留めるメンバーが 1 人も居なければ、向きだけ保存済みの重心から維持する。
    @Test("メンバーが全滅しても、保存済みの重心があれば種は残る")
    func fallsBackToTheStoredCentroid() {
        let r = build([.init(clusterID: 9, name: "私", members: [])],
                      embeddings: [:], stored: [9: vector(4)])
        #expect(r.seeds.map(\.id) == [9])
    }

    @Test("保存済みの重心も無ければ種を作らない")
    func noSeedWithoutAnyCentroid() {
        let r = build([.init(clusterID: 9, name: "私", members: [])], embeddings: [:])
        #expect(r.seeds.isEmpty)
    }
}

/// レビューが拾った回帰（ADR-198 のレビュー）: 2 人の無名命名済みが同じクラスタへ合流したとき、
/// **利用者が付けた名前が 1 つ消える**。旧実装は行き先の名前をその場で読み直していたので
/// 2 人目は見送られていた。反映側で「もう名前が入った先」を除く必要がある。
@Suite("名前の追随：行き先の取り合い（レビュー回帰）")
struct FaceNameFollowingCollisionTests {

    @Test("回帰: 2 人が同じ無名クラスタへ流れても、名前を上書きしない")
    func twoNamesDoNotCollide() {
        let candidates = [
            FaceNameFollowing.Candidate(clusterID: 1, name: "私", faceIDs: ["a", "b"]),
            FaceNameFollowing.Candidate(clusterID: 2, name: "娘", faceIDs: ["c", "d"]),
        ]
        let assignment = ["a": 9, "b": 9, "c": 9, "d": 9]
        // 純ロジックは「どちらも 9 へ行ける」と答える——**反映側で捌く**のが仕様。
        var available: Set<Int> = [9]
        var applied: [FaceNameFollowing.Move] = []
        for move in FaceNameFollowing.moves(candidates: candidates, assignment: assignment,
                                            isUnnamed: { available.contains($0) }) {
            guard available.contains(move.to) else { continue }
            applied.append(move)
            available.remove(move.to)
        }
        #expect(applied.count == 1, "2 つ適用すると 1 人目の名前が消える: \(applied)")
    }
}
