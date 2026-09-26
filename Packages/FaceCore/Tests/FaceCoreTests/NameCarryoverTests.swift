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

    // MARK: - 札の割り当て（純）

    /// 札は `linkClusters` が「束ねたクラスタ ID の最小値」＝ 0 以上を使う。持ち越した札が
    /// その並びに入ると、再スキャンで生まれた無関係な束ねと**同じ値**になり得る（別人が 1 人になる）。
    @Test("持ち越した束ねの札は必ず負（新しい束ねとぶつからない）")
    func carriedTagsAreAlwaysNegative() {
        let tags = CarriedAssertion.carriedBundleTags(for: Array(0...50), usedTags: [])
        #expect(tags.count == 51)
        #expect(tags.values.allSatisfy { $0 < 0 }, "正のままの札がある: \(tags)")
        #expect(Set(tags.values).count == 51, "別々の束ねが同じ札になった")
    }

    @Test("既に持ち越した札（負）はそのまま（何度持ち越しても動かない）")
    func carriedTagsKeepAlreadyCarriedValues() {
        let tags = CarriedAssertion.carriedBundleTags(for: [-4, -1], usedTags: [-4, -1])
        #expect(tags == [-4: -4, -1: -1])
    }

    /// ⚠️ **これが `-(old + 1)` 式では壊れていたところ**（レビュー指摘）。
    /// 世代 1 で札 3 を持ち越して -4 にしたあと、利用者の新しい束ねの最小クラスタ ID が
    /// たまたま 3 なら札は 3 になる。式だと世代 2 で -4（そのまま）と 3（→ -4）が
    /// **同じ値**になり、別人が 1 人に融合していた。
    @Test("2 世代跨いでも、旧札と新しい束ねが同じ札にならない")
    func carriedTagsDoNotCollideAcrossTwoGenerations() {
        // 台帳には前の世代で持ち越した -4 が居る。新しい束ねの札は 3。
        let tags = CarriedAssertion.carriedBundleTags(for: [-4, 3], usedTags: [-4, 3])
        #expect(tags[-4] == -4, "持ち越し済みの札が動いた")
        #expect(tags[3] != -4, "旧札とぶつかった（別人が 1 人に融合する）")
        #expect((tags[3] ?? 0) < 0, "新しい札が負でない")
    }

    @Test("台帳に在る札は避ける（空いている番号から取る）")
    func carriedTagsAvoidTagsAlreadyInTheLedger() {
        let tags = CarriedAssertion.carriedBundleTags(for: [5, 6], usedTags: [-1, -2, -4])
        #expect(Set(tags.values).isDisjoint(with: [-1, -2, -4]), "在る札とぶつかった: \(tags)")
        #expect(Set(tags.values).count == 2)
    }

    /// ⚠️ 持ち越し済みの札は**台帳にまだ現れていない**ことがある（その束ねのクラスタが
    /// まだ再スキャンされていない）。台帳だけを見て空きを取ると、**まだ戻っていない束ねの札を
    /// 新しい束ねに配ってしまい**、後で両方が戻ってきたときに別人が 1 人に融合する。
    @Test("台帳に無くても、入力に居る持ち越し済みの札は避ける")
    func carriedTagsAvoidPendingTagsNotYetInTheLedger() {
        // -1 は戻り待ち（台帳にはまだ無い）。9 は新しく札を要る束ね。
        let tags = CarriedAssertion.carriedBundleTags(for: [-1, 9], usedTags: [])
        #expect(tags[-1] == -1)
        #expect(tags[9] != -1, "戻り待ちの札を新しい束ねに配った（別人が融合する）")
        #expect((tags[9] ?? 0) < 0)
    }

    @Test("同じ入力なら同じ札（呼ぶ順で変わらない）")
    func carriedTagsAreDeterministic() {
        let a = CarriedAssertion.carriedBundleTags(for: [9, 4, 9], usedTags: [-1])
        let b = CarriedAssertion.carriedBundleTags(for: [9, 4], usedTags: [-1])
        #expect(a == b)
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

    // MARK: - 控えの重ね方（純）

    @Test("戻り待ちと新しい控えを重ねる（重複は 1 件）")
    func mergedKeepsBothAndDedupes() {
        let a = CarriedAssertion(name: "現役", memberRefKeys: ["L-a0", "L-a1"])
        let b = CarriedAssertion(name: "戻り待ち", memberRefKeys: ["L-gone0"])
        let merged = CarriedAssertion.merged(snapshot: [a], pending: [b, a], limit: 100)
        #expect(merged.count == 2, "重複が落ちていない: \(merged.compactMap(\.name))")
        #expect(merged.compactMap(\.name).contains("戻り待ち"))
        #expect(merged.compactMap(\.name).contains("現役"))
    }

    /// ⚠️ `memberRefKeys` の元は `Set` なので、アプリを開き直すと同じ写真の集合でも
    /// 並びが変わる。並べずに比べると、開き直したあとの再スキャンで同じ表明がもう 1 件積まれる。
    @Test("写真の並びが違うだけの控えは同じものとして 1 件に畳む")
    func mergedIgnoresRefKeyOrder() {
        let a = CarriedAssertion(name: "太郎", memberRefKeys: ["L-a0", "L-a1", "L-a2"])
        let shuffled = CarriedAssertion(name: "太郎", memberRefKeys: ["L-a2", "L-a0", "L-a1"])
        #expect(CarriedAssertion.merged(snapshot: [a], pending: [shuffled], limit: 100).count == 1)
    }

    /// ⚠️ **上限で落ちるのは後ろ**なので、順番が「どちらを諦めるか」を決めてしまう。
    /// 戻り待ちは既に一度戻せなかったもの、スナップショットは**今まさに消そうとしている**もの
    /// ——後者を優先しないと、異常時に「今の人物が丸ごと控えられない」ことになる。
    @Test("上限を超えるときは、今のスナップショットを先に残す")
    func mergedPrefersTheFreshSnapshotOnOverflow() {
        let pending = (0..<5).map { CarriedAssertion(name: "旧\($0)", memberRefKeys: ["L-p\($0)"]) }
        let snapshot = (0..<5).map { CarriedAssertion(name: "新\($0)", memberRefKeys: ["L-s\($0)"]) }
        let merged = CarriedAssertion.merged(snapshot: snapshot, pending: pending, limit: 5)
        #expect(merged.count == 5)
        #expect(merged.allSatisfy { ($0.name ?? "").hasPrefix("新") },
                "上限で今のスナップショットが落ちた: \(merged.compactMap(\.name))")
    }

    @Test("表明が何も無い控えは持ち越さない（refKey だけでは意味がない）")
    func assertionlessEntryIsNotCarried() {
        #expect(!CarriedAssertion(name: nil, memberRefKeys: ["L-a0"]).isAsserted)
        #expect(!CarriedAssertion(name: "", memberRefKeys: ["L-a0"]).isAsserted)
        #expect(CarriedAssertion(name: "太郎", memberRefKeys: []).isAsserted)
        #expect(CarriedAssertion(name: nil, personGroupID: 3, memberRefKeys: []).isAsserted)
        #expect(CarriedAssertion(name: nil, peopleGroupIDs: [UUID()], memberRefKeys: []).isAsserted)
    }

    // MARK: - 控えの重ね方（ストア）

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

    /// ⚠️ **札は晩を跨いで同じでなければならない**（ADR-232）。1 晩目に割り当てた札を
    /// 残りのエントリへ書き戻さないと、2 晩目にもう一度「空いている札」を取りに行って
    /// **別の札**になり、同じ子の時期クラスタが 2 人に割れる。
    @Test("束ねが数晩に分かれて戻っても、同じ札になる")
    func bundleTagIsStableAcrossNights() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        await seedTwoClusters(store, vecA: [1, 0, 0], vecB: [0, 1, 0])
        let before = await store.allClusters().map(\.clusterID).sorted()
        #expect(before.count == 2, "fixture: 2 クラスタになっていない")
        await store.linkClusters(before)
        let snapshot = await store.assertedClusterEntries()
        #expect(snapshot.allSatisfy { $0.personGroupID != nil }, "fixture: 束ねが控えに乗っていない")
        await store.reset()

        // 1 晩目: A 群だけ再スキャン。
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([0, 0, 1])]) }
        let night1 = await store.reapplyAssertions(snapshot)
        #expect(night1.count == 1, "1 晩目で戻るのは 1 つだけのはず（\(night1.count)）")
        let tagsAfterNight1 = await store.allClusters().compactMap(\.personGroupID)
        #expect(tagsAfterNight1.count == 1, "1 晩目で札が付いていない")
        // ⚠️ 残りのエントリに、割り当てた札が書き戻されていること。
        let carriedTag = night1[0].personGroupID
        #expect(carriedTag == tagsAfterNight1[0],
                "残りに札が書き戻されていない（\(carriedTag as Int?) ≠ \(tagsAfterNight1[0])）")

        // 2 晩目: B 群。
        for i in 0..<4 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([1, 1, 0])]) }
        let night2 = await store.reapplyAssertions(night1)
        #expect(night2.isEmpty, "2 晩目でも戻っていない（\(night2.count) 件）")
        let tags = await store.allClusters().compactMap(\.personGroupID)
        #expect(tags.count == 2, "札が 2 つ付いていない: \(tags)")
        #expect(Set(tags).count == 1, "晩を跨いで札が変わった＝同じ子が 2 人に割れた: \(tags)")
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
