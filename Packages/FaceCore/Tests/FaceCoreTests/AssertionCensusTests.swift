import CoreGraphics
import Foundation
import PerceptionCore
import Testing
@testable import FaceCore

/// **表明の国勢調査**（ADR-233）。遷移の前後で「利用者が手で作ったもの」が減っていないか。
///
/// ⚠️ これは「デバッグしなくても壊れたら分かる」ための仕掛けなので、**見落としが一番の失敗**。
/// 今日直した経路（名前・束ね・家族グループ・別人の居座り）を 1 つずつ固定する。
@Suite("表明の国勢調査（遷移の前後の突き合わせ）")
struct AssertionCensusTests {

    private func person(_ id: Int, name: String? = nil, bundle: Int? = nil,
                        cover: Bool = false, confirmed: Int = 0,
                        photos: [String] = []) -> AssertionCensus.Person {
        .init(clusterID: id, name: name, personGroupID: bundle, hasCover: cover,
              confirmedFaces: confirmed, refKeys: Set(photos))
    }

    private func census(_ people: [AssertionCensus.Person],
                        _ groups: [AssertionCensus.Group] = []) -> AssertionCensus {
        .init(people: people, groups: groups)
    }

    // MARK: - 何も減っていないとき

    @Test("何も減っていなければ何も言わない（偽の警告を出さない）")
    func quietWhenNothingLost() {
        let before = census([person(1, name: "太郎", photos: ["a", "b", "c"])])
        // ID が振り直され、写真が 1 枚増えた＝正常な遷移。
        let after = census([person(9, name: "太郎", photos: ["a", "b", "c", "d"])])
        #expect(AssertionCensus.diff(before: before, after: after).isEmpty)
    }

    /// ⚠️ **増えたことは報告しない**。再スキャンで人物が増えるのは正常で、報告すると
    /// 本当の損失が埋もれる（256KB の記録を同じ行で押し流した前例がある）。
    @Test("人物が増えても報告しない")
    func quietWhenPeopleAdded() {
        let before = census([person(1, name: "太郎", photos: ["a", "b"])])
        let after = census([person(1, name: "太郎", photos: ["a", "b"]),
                            person(2, photos: ["x", "y"])])
        #expect(AssertionCensus.diff(before: before, after: after).isEmpty)
    }

    // MARK: - 名前

    @Test("名前が消えたら報告する（人物ごと消えた／名前だけ抜けた を区別する）")
    func reportsLostNames() {
        let before = census([person(1, name: "太郎", photos: ["a", "b", "c"]),
                             person(2, name: "花子", photos: ["x", "y", "z"])])
        // 太郎は人物ごと消えた。花子は行が残って名前だけ抜けた。
        let after = census([person(2, photos: ["x", "y", "z"])])
        let findings = AssertionCensus.diff(before: before, after: after)
        let names = findings.filter { $0.kind == .nameLost }
        #expect(names.count == 2, "\(findings)")
        #expect(names.first(where: { $0.subject == "太郎" })?.detail == "人物ごと消えた")
        #expect(names.first(where: { $0.subject == "花子" })?.detail == "名前だけ抜けた")
    }

    /// ⚠️ **突き合わせの鍵は写真**。clusterID は遷移で振り直されるので、ID で突き合わせると
    /// 正常な再クラスタでも「全員消えた」になり、警告が意味を失う。
    @Test("clusterID が全部変わっても、写真が同じなら消えたと言わない")
    func matchesByPhotosNotByClusterID() {
        let before = census([person(1, name: "太郎", photos: ["a", "b", "c"])])
        let after = census([person(777, name: "太郎", photos: ["a", "b", "c"])])
        #expect(AssertionCensus.diff(before: before, after: after).isEmpty)
    }

    // MARK: - 束ね・代表写真・確認顔

    @Test("束ねがほどけたら報告する")
    func reportsLostBundles() {
        let before = census([person(1, name: "子", bundle: 1, photos: ["a", "b"]),
                             person(2, name: "子", bundle: 1, photos: ["c", "d"])])
        let after = census([person(1, name: "子", photos: ["a", "b"]),
                            person(2, name: "子", photos: ["c", "d"])])
        let findings = AssertionCensus.diff(before: before, after: after)
        #expect(findings.filter { $0.kind == .bundleLost }.count == 2)
    }

    @Test("代表写真の指定と確認顔が減ったら報告する")
    func reportsLostCoverAndConfirmations() {
        let before = census([person(1, name: "太郎", cover: true, confirmed: 5, photos: ["a", "b"])])
        let after = census([person(1, name: "太郎", cover: false, confirmed: 2, photos: ["a", "b"])])
        let kinds = AssertionCensus.diff(before: before, after: after).map(\.kind)
        #expect(kinds.contains(.coverLost))
        #expect(kinds.contains(.confirmationsLost))
    }

    // MARK: - 家族グループ

    @Test("グループのメンバーが解決できなくなったら報告する")
    func reportsLostGroupMembers() {
        let g = AssertionCensus.Group(id: UUID(), name: "家族", memberClusterIDs: [1, 2])
        let before = census([person(1, name: "父", photos: ["a", "b"]),
                             person(2, photos: ["c", "d"])], [g])
        // 2 の行が消えた（記録には残っている）。
        let after = census([person(1, name: "父", photos: ["a", "b"])], [g])
        let findings = AssertionCensus.diff(before: before, after: after)
        #expect(findings.contains { $0.kind == .groupMemberLost && $0.subject == "家族" },
                "\(findings)")
    }

    @Test("グループの行ごと消えたら報告する")
    func reportsLostGroups() {
        let g = AssertionCensus.Group(id: UUID(), name: "家族", memberClusterIDs: [1])
        let before = census([person(1, name: "父", photos: ["a"])], [g])
        let after = census([person(1, name: "父", photos: ["a"])], [])
        #expect(AssertionCensus.diff(before: before, after: after)
            .contains { $0.kind == .groupLost })
    }

    /// ⚠️⚠️ **これが「数だけでは足りない」ケース**。メンバー数は 2 のままで減っていないが、
    /// `reset()` が clusterID を振り直したのに記録が古い ID を指していると、**別人が家族に
    /// 居座る**（実際に踏んだ）。数を数えるだけの監査では永久に見えない。
    @Test("数が同じでも、同じ ID が別人を指すようになったら報告する")
    func reportsSwappedGroupMembers() {
        let g = AssertionCensus.Group(id: UUID(), name: "家族", memberClusterIDs: [1, 2])
        let before = census([person(1, name: "父", photos: ["a", "b", "c"]),
                             person(2, name: "母", photos: ["d", "e", "f"])], [g])
        // ID 2 が、まったく別の写真の人物になった（番号の再利用）。
        let after = census([person(1, name: "父", photos: ["a", "b", "c"]),
                            person(2, photos: ["x", "y", "z"])], [g])
        let findings = AssertionCensus.diff(before: before, after: after)
        #expect(findings.contains { $0.kind == .groupMemberSwapped },
                "別人の居座りを見逃した: \(findings)")
    }

    @Test("写真が少し入れ替わっただけでは「別人」と言わない（日常の出入り）")
    func toleratesNormalChurn() {
        let g = AssertionCensus.Group(id: UUID(), name: "家族", memberClusterIDs: [1])
        let before = census([person(1, name: "父", photos: ["a", "b", "c", "d", "e"])], [g])
        // 1 枚消えて 1 枚増えた＝同じ人。
        let after = census([person(1, name: "父", photos: ["a", "b", "c", "d", "f"])], [g])
        #expect(AssertionCensus.diff(before: before, after: after).isEmpty)
    }

    // MARK: - まとめの 1 行

    /// ⚠️ **何も減っていなくても 1 行は出す**。「出ていない」と「そもそも走っていない」を
    /// 区別できないログは、後から見て役に立たない（ADR-207 で同じ失敗をしている）。
    @Test("まとめの行は、変わっていない項目も数を出す")
    func summaryAlwaysShowsNumbers() {
        let g = AssertionCensus.Group(id: UUID(), name: "家族", memberClusterIDs: [1, 2])
        let before = census([person(1, name: "父", bundle: 1, cover: true, confirmed: 3, photos: ["a"]),
                             person(2, name: "母", photos: ["b"])], [g])
        let after = census([person(1, name: "父", photos: ["a"])], [g])
        let line = AssertionCensus.summary(before: before, after: after)
        #expect(line.contains("named=2→1"), "\(line)")
        #expect(line.contains("bundles=1→0"), "\(line)")
        #expect(line.contains("covers=1→0"), "\(line)")
        #expect(line.contains("confirmed=3→0"), "\(line)")
        #expect(line.contains("groupMembers=2→1"), "\(line)")
        #expect(line.contains("groups=1"), "変わっていない項目も数を出す: \(line)")
    }

    // MARK: - 台帳から数える（ストア連携）

    private func signal(_ v: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
                           embedding: ClipMath.encodeHalf(v), quality: 0.9)
    }

    @Test("台帳から表明を数え上げられる（名前・束ね・代表・グループ）")
    func countsFromTheLedger() async {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<4 { await store.recordScan(refKey: "L-a\(i)", faces: [signal([1, 0, 0])]) }
        for i in 0..<4 { await store.recordScan(refKey: "L-b\(i)", faces: [signal([0, 1, 0])]) }
        let ids = await store.allClusters().map(\.clusterID).sorted()
        #expect(ids.count == 2, "fixture: 2 クラスタになっていない")
        await store.rename(clusterID: ids[0], name: "父")
        await store.linkClusters(ids)
        _ = await store.createPeopleGroup(name: "家族", memberClusterIDs: ids)

        let census = await store.assertionCensus()
        #expect(census.namedCount == 1)
        #expect(census.bundleCount == 1, "束ねの札が数えられていない")
        #expect(census.groups.count == 1)
        #expect(census.resolvedGroupMemberCount == 2)
        #expect(census.people.count == 2)
        #expect(census.people.allSatisfy { !$0.refKeys.isEmpty }, "写真が入っていない＝入れ替わりを見られない")
    }

    /// ⚠️ 実ライブラリでは 1,300 人・8 万顔なので、**人物ごとに引いたら 1,300 往復**になる
    /// （ADR-119）。射影 1 回で取ることを回数で固定する。
    @Test("数え上げは人物数に比例して fetch しない")
    func censusDoesNotScaleWithPeople() async {
        func makeStore(people: Int) async -> FaceStore {
            let store = FaceStore(isStoredInMemoryOnly: true)
            for p in 0..<people {
                var vector = [Float](repeating: 0, count: people)
                vector[p] = 1
                for shot in 0..<3 {
                    await store.recordScan(refKey: "L-\(p)-\(shot)", faces: [signal(vector)])
                }
            }
            return store
        }
        let small = await makeStore(people: 20)
        let large = await makeStore(people: 80)
        #expect(await small.allClusters().count == 20, "fixture: 20 人になっていない")
        #expect(await large.allClusters().count == 80, "fixture: 80 人になっていない")

        func fetchCount(_ store: FaceStore, _ body: () async -> Void) async -> Int {
            let before = await store.fetchCountForTesting
            await body()
            return await store.fetchCountForTesting - before
        }
        let smallCount = await fetchCount(small) { _ = await small.assertionCensus() }
        let largeCount = await fetchCount(large) { _ = await large.assertionCensus() }
        #expect(smallCount > 0, "そもそも引いていない")
        #expect(largeCount <= smallCount * 2,
                "人物が 4 倍で fetch が \(smallCount)→\(largeCount) 回（比例している）")
    }
}
