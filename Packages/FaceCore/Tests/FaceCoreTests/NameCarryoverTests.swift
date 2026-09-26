import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// 版上げ後の名前の持ち越し（ADR-169）。純ロジックの一対一対応。
///
/// ⚠️ 旧実装は旧人物ごとに「重なり最大」を貪欲に取っていた。局所的な最良ペアが
/// **別の旧人物にとって唯一の対応先**を奪うと、存在する一対一対応を見逃して名前が戻らない。
@Suite("名前の持ち越し（一対一対応）")
struct NameCarryoverMatchingTests {

    @Test("唯一の対応先を奪わない（貪欲だと片方が戻らない）")
    func doesNotStealTheOnlyCandidate() {
        // A は X(5) と Y(4) に対応でき、B は X(3) しか無い。
        // 貪欲: A→X を取ると B は行き先を失う。正解は A→Y, B→X。
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 5, 2: 4]),
            .init(name: "B", candidates: [1: 3]),
        ])
        #expect(unmatched.isEmpty, "両方戻せるはずなのに片方が未確定: \(unmatched)")
        #expect(assignments[0] == 2 && assignments[1] == 1,
                "唯一の候補を奪っている: \(assignments)")
    }

    /// この不具合の本体。**同名の別人**（"太郎" が 2 人）が別々の人物へ戻ること。
    @Test("同名の別人でも、それぞれ別の人物へ戻る")
    func sameNameDifferentPeople() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "太郎", candidates: [10: 8]),
            .init(name: "太郎", candidates: [11: 6]),
        ])
        #expect(unmatched.isEmpty, "同名を理由に片方が捨てられている")
        #expect(assignments[0] == 10 && assignments[1] == 11)
        #expect(Set(assignments.values).count == 2, "2 人が同じクラスタへ割り当てられている")
    }

    @Test("1 つの人物へ 2 つの名前は割り当てない")
    func oneClusterOneName() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 9]),
            .init(name: "B", candidates: [1: 8]),
        ])
        #expect(assignments.count == 1, "同じクラスタに 2 つ割り当てている: \(assignments)")
        #expect(unmatched.count == 1, "行き先の無いエントリが残りに入っていない")
    }

    @Test("候補が無いエントリは残りに入る（黙って消えない）")
    func noCandidateIsKept() {
        let (assignments, unmatched) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [:]),
        ])
        #expect(assignments.isEmpty)
        #expect(unmatched == [0], "候補ゼロのエントリが失われている")
    }

    @Test("同数を戻せるなら重なりの大きい対を選ぶ")
    func prefersLargerOverlapWhenTied() {
        let (assignments, _) = NameCarryoverMatching.match([
            .init(name: "A", candidates: [1: 2, 2: 9]),
        ])
        #expect(assignments[0] == 2, "重なりの小さい方を選んでいる")
    }

    @Test("空入力は空を返す")
    func emptyInput() {
        let (assignments, unmatched) = NameCarryoverMatching.match([])
        #expect(assignments.isEmpty && unmatched.isEmpty)
    }
}

/// ストア越しの振る舞い（`reapplyAssertions`）。
@Suite("表明の持ち越し（ストア）", .serialized)
struct NameCarryoverStoreTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// ⚠️ **同名の別人**を作って、2 人目の名前が消えないことを見る。
    /// 旧実装は「同名クラスタが既にある」だけで `continue` し、残りにも積まなかったため、
    /// 2 人目の名前と旧メンバーの対応が永久に失われていた。
    @Test("同名の別人でも 2 人目の名前が失われない")
    func sameNameSurvives() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        for i in 0..<4 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, Float(i) * 0.005])]) }
        let map = await store.memberRefKeysByCluster()
        #expect(map.count >= 2, "fixture: 2 クラスタになっていない")

        // 旧版で「太郎」が 2 人いた状態の持ち越し（メンバーは今のクラスタと重なる）。
        let entries: [CarriedAssertion] = [
            .init(name: "太郎", memberRefKeys: ["L-a0", "L-a1", "L-a2", "L-a3"]),
            .init(name: "太郎", memberRefKeys: ["L-b0", "L-b1", "L-b2", "L-b3"]),
        ]
        let remaining = await store.reapplyAssertions(entries)
        #expect(remaining.isEmpty, "戻せるはずの名前が残っている: \(remaining.count)")

        let named = await store.allClusters().filter { $0.name == "太郎" }
        #expect(named.count == 2, "同名の別人が 2 人とも命名されていない（\(named.count) 人）")
    }

    @Test("対応先が無い名前は残りとして返る（次回に再評価できる）")
    func unmatchedIsReturned() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, Float(i) * 0.005, 0])]) }
        // どの写真とも重ならない持ち越し。
        let remaining = await store.reapplyAssertions(
            [.init(name: "花子", memberRefKeys: ["L-zz0", "L-zz1", "L-zz2"])])
        #expect(remaining.count == 1, "行き先の無い名前が黙って消えている")
        #expect(remaining.first?.name == "花子")
        #expect(remaining.first?.memberRefKeys.count == 3, "旧メンバーの対応まで失っている")
    }
}

/// **名前以外の表明**の持ち越し（ADR-232）。束ね（`personGroupID`）とピープルグループの所属は、
/// 名前と同じ重みのユーザーの表明なのに、版上げ再スキャンで黙って消えていた。
@Suite("表明の持ち越し: 束ねとグループ所属", .serialized)
struct CarriedAssertionTests {

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    /// 2 つの離れたクラスタを作る（A 群 = L-a*, B 群 = L-b*）。
    private func seedTwoClusters(_ store: FaceStore, vecA: [Float], vecB: [Float]) async {
        for i in 0..<4 {
            await store.recordScan(refKey: "L-a\(i)", faces: [signal(vecA)])
        }
        for i in 0..<4 {
            await store.recordScan(refKey: "L-b\(i)", faces: [signal(vecB)])
        }
    }

    // MARK: - 札の並び（純）

    /// 札は `linkClusters` が「束ねたクラスタ ID の最小値」＝ 0 以上を使う。持ち越した札が
    /// その並びに入ると、再スキャンで生まれた無関係な束ねと**同じ値**になり得る（別人が 1 人になる）。
    @Test("持ち越した束ねの札は必ず負（新しい束ねとぶつからない）")
    func carriedGroupIDNeverCollidesWithClusterIDs() {
        for old in 0...50 {
            #expect(CarriedAssertion.carriedPersonGroupID(old) < 0, "札 \(old) が正のまま")
        }
        // 違う札は違う値のまま（別々の束ねが 1 つに混ざらない）。
        let mapped = Set((0...50).map { CarriedAssertion.carriedPersonGroupID($0) })
        #expect(mapped.count == 51)
    }

    @Test("何度持ち越しても札は動かない（世代を 2 回跨いでも束ねが割れない）")
    func carriedGroupIDIsStableUnderRecarry() {
        let once = CarriedAssertion.carriedPersonGroupID(7)
        #expect(CarriedAssertion.carriedPersonGroupID(once) == once)
    }

    // MARK: - 旧形式の互換

    /// 名前しか持ち越していなかった頃のファイルが残っている。読めなくなると
    /// **持ち越し待ちの名前が丸ごと消える**。
    @Test("旧形式（name/memberRefKeys だけ）の控えも読める")
    func decodesLegacyCarryoverFile() throws {
        let json = #"{"name":"太郎","memberRefKeys":["L-a0","L-a1"]}"#
        let entry = try JSONDecoder().decode(CarriedAssertion.self, from: Data(json.utf8))
        #expect(entry.name == "太郎")
        #expect(entry.memberRefKeys == ["L-a0", "L-a1"])
        #expect(entry.personGroupID == nil)
        #expect(entry.peopleGroupIDs.isEmpty)
    }

    // MARK: - 控えの重ね方

    /// ⚠️ **戻り待ちを踏み潰さない**（ADR-232）。控えに残っているのは「まだ戻せていない人」で、
    /// ストアには存在しない＝スナップショットには入らない。上書きすると、再スキャンの途中で
    /// もう一度やり直したときに戻り待ちの名前が丸ごと消える。
    /// `@MainActor`: `PeopleEngine` は MainActor 隔離（控えの読み書きもそこで行う）。
    @Test("再スキャンをやり直しても、戻り待ちの表明が消えない")
    @MainActor
    func rescanDoesNotDropPendingCarryover() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        let engine = PeopleEngine(faceProvider: nil, store: store)
        // ⚠️ 控えは**実ファイル**（Application Support）なので、前後で必ず消す。
        // 消さないと前の実行の残りを読み、結果が実行順に依存する。
        engine.saveCarryover(nil)
        defer { engine.saveCarryover(nil) }
        // 戻り待ちが 1 件ある状態（ストアには対応する人物が居ない）。
        engine.saveCarryover(.init(savedAt: Date(), entries: [
            .init(name: "戻り待ち", memberRefKeys: ["L-gone0", "L-gone1"]),
        ]))
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        let ids = await store.allClusters().map(\.clusterID)
        #expect(ids.count == 1, "fixture: 1 クラスタになっていない")
        await store.rename(clusterID: ids[0], name: "現役")

        let merged = await engine.snapshotAssertionsForRescan()
        let names = merged.compactMap(\.name)
        #expect(names.contains("戻り待ち"), "戻り待ちの控えが踏み潰された: \(names)")
        #expect(names.contains("現役"), "今の人物が控えられていない: \(names)")
        // 同じものを 2 度積まない。
        let again = await engine.snapshotAssertionsForRescan()
        #expect(again.count == merged.count, "同じ表明が二重に積まれた（\(merged.count) → \(again.count)）")
    }

    // MARK: - 束ね（ADR-61）

    @Test("束ね（personGroupID）が再スキャンを跨いで戻る")
    func bundlingSurvivesRescan() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seedTwoClusters(store, vecA: [1, 0, 0], vecB: [0, 1, 0])
        let before = await store.allClusters().map(\.clusterID).sorted()
        #expect(before.count == 2, "fixture: 2 クラスタになっていない（\(before.count)）")
        await store.linkClusters(before)
        let linked = await store.allClusters().compactMap(\.personGroupID)
        #expect(linked.count == 2 && Set(linked).count == 1, "fixture: 束ねられていない")

        let snapshot = await store.assertedClusterEntries()
        #expect(snapshot.count == 2, "無名でも束ねがあれば控えるはず（\(snapshot.count) 件）")
        #expect(snapshot.allSatisfy { $0.personGroupID != nil })

        await store.reset()
        // 埋め込みは新しいパイプラインのもの（値が変わっても写真は同じ）。
        await seedTwoClusters(store, vecA: [0, 0, 1], vecB: [1, 1, 0])
        let remaining = await store.reapplyAssertions(snapshot)
        #expect(remaining.isEmpty, "戻せるはずの束ねが残っている（\(remaining.count) 件）")

        let after = await store.allClusters()
        let gids = after.compactMap(\.personGroupID)
        #expect(gids.count == 2, "束ねが戻っていない（\(gids.count)/\(after.count)）")
        #expect(Set(gids).count == 1, "同じ 1 人に束ね直されていない: \(gids)")
        #expect(gids.allSatisfy { $0 < 0 }, "持ち越しの札が新しい束ねの並びに入っている: \(gids)")
    }

    // MARK: - ピープルグループの所属（ADR-231/232）

    /// ⚠️ **無名のメンバー**で確かめる。旧実装は控えの対象を「名前付き」に絞っていたので、
    /// このケースはそもそも控えられず、再スキャンで家族グループから黙って消えていた。
    @Test("ピープルグループの所属が再スキャンを跨いで戻る（無名のメンバーでも）")
    func peopleGroupMembershipSurvivesRescan() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seedTwoClusters(store, vecA: [1, 0, 0], vecB: [0, 1, 0])
        let before = await store.allClusters().map(\.clusterID).sorted()
        #expect(before.count == 2, "fixture: 2 クラスタになっていない")
        let groupID = await store.createPeopleGroup(name: "家族", memberClusterIDs: before)

        let snapshot = await store.assertedClusterEntries()
        #expect(snapshot.count == 2, "無名でもグループ所属があれば控えるはず（\(snapshot.count) 件）")
        #expect(snapshot.allSatisfy { $0.peopleGroupIDs == [groupID] })

        await store.reset()
        // ⚠️ 消した直後は**メンバーが空**になっていること（ID が意味を失うので残せない）。
        let cleared = await store.allPeopleGroupRecords()
        #expect(cleared.first?.memberClusterIDs.isEmpty == true,
                "意味を失った clusterID がグループに残っている（別人が居座る）")

        await seedTwoClusters(store, vecA: [0, 0, 1], vecB: [1, 1, 0])
        let remaining = await store.reapplyAssertions(snapshot)
        #expect(remaining.isEmpty, "戻せるはずのグループ所属が残っている（\(remaining.count) 件）")

        let records = await store.allPeopleGroupRecords()
        #expect(records.count == 1, "グループの行が増減した（\(records.count)）")
        let live = Set(await store.allClusters().map(\.clusterID))
        let members = Set(records[0].memberClusterIDs)
        #expect(members.count == 2, "グループのメンバーが戻っていない: \(members.sorted())")
        #expect(members.isSubset(of: live), "生きていない人物がメンバーに入っている")
    }

    /// 再スキャンは数晩に分かれる。1 回で戻せるのはメンバーの一部なので、
    /// **毎回上書きすると前の晩に戻した人が消える**。
    @Test("数晩に分かれて戻っても、前の晩のメンバーが消えない")
    func partialRestoreKeepsEarlierMembers() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seedTwoClusters(store, vecA: [1, 0, 0], vecB: [0, 1, 0])
        let before = await store.allClusters().map(\.clusterID).sorted()
        #expect(before.count == 2, "fixture: 2 クラスタになっていない")
        _ = await store.createPeopleGroup(name: "家族", memberClusterIDs: before)
        let snapshot = await store.assertedClusterEntries()
        await store.reset()

        // 1 晩目: A 群だけ再スキャンされた。
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([0, 0, 1])]) }
        let afterNight1 = await store.reapplyAssertions(snapshot)
        #expect(afterNight1.count == 1, "1 晩目で戻るのは 1 人だけのはず（\(afterNight1.count)）")
        let night1Members = await store.allPeopleGroupRecords()[0].memberClusterIDs
        #expect(night1Members.count == 1, "1 晩目のメンバー: \(night1Members)")

        // 2 晩目: B 群が再スキャンされた。
        for i in 0..<4 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([1, 1, 0])]) }
        let afterNight2 = await store.reapplyAssertions(afterNight1)
        #expect(afterNight2.isEmpty, "2 晩目でも戻っていない（\(afterNight2.count) 件）")
        let night2Members = await store.allPeopleGroupRecords()[0].memberClusterIDs
        #expect(Set(night2Members).isSuperset(of: Set(night1Members)),
                "1 晩目に戻したメンバーが上書きで消えた: \(night1Members) → \(night2Members)")
        #expect(night2Members.count == 2, "2 人揃っていない: \(night2Members)")
    }
}
