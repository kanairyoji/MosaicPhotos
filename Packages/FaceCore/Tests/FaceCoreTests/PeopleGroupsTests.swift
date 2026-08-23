import PerceptionCore
import CoreGraphics
import Foundation
import Testing
@testable import FaceCore

/// ピープルグループ（複数人物の名前付き束・ADR-113）: 解決の純ロジックとストア連携。
@Suite("PeopleGroups (ピープルグループ)")
struct PeopleGroupsTests {

    // MARK: - 解決（純）

    private func person(_ id: Int, refKeys: [String]) -> PersonInfo {
        PersonInfo(clusterID: id, name: nil, count: refKeys.count,
                   coverRefKey: refKeys.first, coverBoundingBox: nil, memberRefKeys: refKeys)
    }

    @Test("メンバーの写真キーは重複排除して合成される（メンバー順）")
    func resolveUnionsRefKeys() {
        let info = PeopleGroupInfo.resolve(
            id: UUID(), name: "Family", memberClusterIDs: [1, 2], createdAt: Date(),
            people: [person(1, refKeys: ["L-a", "L-b"]), person(2, refKeys: ["L-b", "L-c"])])
        #expect(info.memberRefKeys == ["L-a", "L-b", "L-c"])
        #expect(info.photoCount == 3)
        #expect(info.members.map(\.clusterID) == [1, 2])
    }

    @Test("現在の一覧に居ないメンバーは表示から外れるが記録には残る")
    func resolveSkipsMissingMembers() {
        let info = PeopleGroupInfo.resolve(
            id: UUID(), name: "Family", memberClusterIDs: [1, 99], createdAt: Date(),
            people: [person(1, refKeys: ["L-a"])])
        #expect(info.members.map(\.clusterID) == [1])
        #expect(info.memberClusterIDs == [1, 99], "記録上のメンバーが失われた")
        #expect(info.memberRefKeys == ["L-a"])
    }

    // MARK: - ストア連携

    private func signal(_ vec: [Float]) -> DetectedFaceSignal {
        DetectedFaceSignal(boundingBox: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
                           embedding: ClipMath.encodeHalf(vec), quality: 0.9)
    }

    private func jittered(_ base: [Float], _ i: Int) -> [Float] {
        var v = base
        v[(i % v.count)] += 0.02 * Float((i % 3) + 1)
        return v
    }

    /// 2 人分の顔を持つエンジンを作る。
    @MainActor
    private func makeEngine() async -> PeopleEngine {
        let store = FaceStore(isStoredInMemoryOnly: true)
        for i in 0..<5 { await store.recordScan(refKey: "L-a\(i)", faces: [signal(jittered([1, 0, 0, 0], i))]) }
        for i in 0..<5 { await store.recordScan(refKey: "L-b\(i)", faces: [signal(jittered([0, 1, 0, 0], i))]) }
        let engine = PeopleEngine(faceProvider: nil, store: store)
        await engine.loadPeople()
        return engine
    }

    @Test("作成→一覧→編集→削除の一連の流れ")
    @MainActor
    func createUpdateDeleteFlow() async {
        let engine = await makeEngine()
        let people = engine.people
        #expect(people.count == 2, "前提: 2 人物")

        let id = await engine.createPeopleGroup(name: " Group A ",
                                                memberClusterIDs: people.map(\.clusterID))
        #expect(id != nil)
        #expect(engine.peopleGroups.count == 1)
        #expect(engine.peopleGroups.first?.name == "Group A", "名前が trim されない")
        #expect(engine.peopleGroups.first?.members.count == 2)

        // グループの写真キー（アルバム表示・共有用）。一覧の PersonInfo.memberRefKeys は
        // 遅延取得で空のため（ADR-95）、この API がストアから解決する。
        let refKeys = await engine.memberRefKeys(forGroup: id!)
        #expect(refKeys.count == 10)

        // 名前とメンバーの更新。
        await engine.updatePeopleGroup(id: id!, name: "Group B",
                                       memberClusterIDs: people.map(\.clusterID))
        #expect(engine.peopleGroups.first?.name == "Group B")

        await engine.deletePeopleGroup(id: id!)
        #expect(engine.peopleGroups.isEmpty)
    }

    @Test("メンバー 1 人以下・空名では作成できない")
    @MainActor
    func rejectsInvalidCreation() async {
        let engine = await makeEngine()
        let one = [engine.people[0].clusterID]
        #expect(await engine.createPeopleGroup(name: "X", memberClusterIDs: one) == nil)
        #expect(await engine.createPeopleGroup(name: "   ",
                                               memberClusterIDs: engine.people.map(\.clusterID)) == nil)
        #expect(engine.peopleGroups.isEmpty)
    }

    @Test("人物一覧の再構築（loadPeople）でグループも解決し直される")
    @MainActor
    func groupsReloadWithPeople() async {
        let engine = await makeEngine()
        _ = await engine.createPeopleGroup(name: "G", memberClusterIDs: engine.people.map(\.clusterID))
        #expect(engine.peopleGroups.count == 1)
        await engine.loadPeople()
        #expect(engine.peopleGroups.count == 1, "loadPeople 後にグループが消えた")
    }
}
