import Foundation
import SwiftData

/// ピープルグループ（複数の人物を束ねた名前付きアルバム＝家族・チーム・組織などの単位）。
///
/// ADR-61 の「人物束ね」（同一人物の複数クラスタを 1 人として束ねる）とは**別概念**:
/// こちらは**別人どうし**を家族・組織などの単位でまとめる表示・共有用のグループで、
/// クラスタリングには一切影響しない（メンバーの clusterID を参照するだけ）。
@Model
final class PeopleGroupRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    /// メンバー人物の clusterID（束ね人物は代表 clusterID）。
    var memberClusterIDs: [Int]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, memberClusterIDs: [Int], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.memberClusterIDs = memberClusterIDs
        self.createdAt = createdAt
    }
}

/// ピープルグループの表示用値型（解決済み・Sendable）。
public struct PeopleGroupInfo: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    /// 記録上のメンバー clusterID（編集用・未解決分も含む）。
    public let memberClusterIDs: [Int]
    /// 現在の人物一覧に解決できたメンバー（表示用・記録順）。
    public let members: [PersonInfo]
    /// 全メンバーの写真キー（重複排除・メンバー順）。
    /// ⚠️ ホーム一覧の `PersonInfo.memberRefKeys` は遅延取得で空のため（ADR-95）、
    /// ここも空になり得る。実利用（アルバム表示・共有）は
    /// `PeopleEngine.memberRefKeys(forGroup:)` で解決すること。
    public let memberRefKeys: [String]
    public let createdAt: Date

    public var photoCount: Int { memberRefKeys.count }

    public init(id: UUID, name: String, memberClusterIDs: [Int],
                members: [PersonInfo], memberRefKeys: [String], createdAt: Date) {
        self.id = id
        self.name = name
        self.memberClusterIDs = memberClusterIDs
        self.members = members
        self.memberRefKeys = memberRefKeys
        self.createdAt = createdAt
    }

    /// 記録メンバーと現在の人物一覧から解決済み Info を作る（純ロジック・テスト対象）。
    /// 現在の一覧に居ない clusterID（再クラスタで消えた等）は表示から外すが記録には残す。
    public static func resolve(id: UUID, name: String, memberClusterIDs: [Int],
                               createdAt: Date, people: [PersonInfo]) -> PeopleGroupInfo {
        var byCluster: [Int: PersonInfo] = [:]
        for person in people { byCluster[person.clusterID] = person }
        let members = memberClusterIDs.compactMap { byCluster[$0] }
        var seen = Set<String>()
        var refKeys: [String] = []
        for member in members {
            for key in member.memberRefKeys where seen.insert(key).inserted {
                refKeys.append(key)
            }
        }
        return PeopleGroupInfo(id: id, name: name, memberClusterIDs: memberClusterIDs,
                               members: members, memberRefKeys: refKeys, createdAt: createdAt)
    }
}

// MARK: - FaceStore CRUD

extension FaceStore {

    func allPeopleGroupRecords() -> [(id: UUID, name: String, memberClusterIDs: [Int], createdAt: Date)] {
        let records = (try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return records.map { ($0.id, $0.name, $0.memberClusterIDs, $0.createdAt) }
    }

    func createPeopleGroup(name: String, memberClusterIDs: [Int]) -> UUID {
        let record = PeopleGroupRecord(name: name, memberClusterIDs: memberClusterIDs)
        modelContext.insert(record)
        try? modelContext.save()
        return record.id
    }

    func deletePeopleGroup(id: UUID) {
        let groupID = id
        guard let record = try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>(
            predicate: #Predicate { $0.id == groupID })).first else { return }
        modelContext.delete(record)
        try? modelContext.save()
    }

    /// 名前・メンバーの更新（nil の引数は変更しない）。
    func updatePeopleGroup(id: UUID, name: String?, memberClusterIDs: [Int]?) {
        let groupID = id
        guard let record = try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>(
            predicate: #Predicate { $0.id == groupID })).first else { return }
        if let name { record.name = name }
        if let memberClusterIDs { record.memberClusterIDs = memberClusterIDs }
        try? modelContext.save()
    }
}

// MARK: - PeopleEngine ファサード

extension PeopleEngine {

    /// グループ一覧を読み直す（人物一覧の再構築後・グループ操作後に呼ぶ）。
    public func reloadPeopleGroups() async {
        let records = await store.allPeopleGroupRecords()
        let current = people
        peopleGroups = records.map {
            PeopleGroupInfo.resolve(id: $0.id, name: $0.name,
                                    memberClusterIDs: $0.memberClusterIDs,
                                    createdAt: $0.createdAt, people: current)
        }
    }

    /// 同じ名前のグループが既にあるか（大小・前後空白を無視。`excluding` は自分自身の編集用）。
    /// クラウド共有のフォルダ名がグループ名から決まるため、**同名は作らせない**
    /// （連番フォルダ `◯◯ 2` ができて分かりにくくなる・実フィードバック）。
    public func peopleGroupNameExists(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return peopleGroups.contains {
            $0.id != id && $0.name.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
    }

    /// グループを作成する（メンバー 2 人以上・名前必須・**同名不可**）。作成できたら ID を返す。
    @discardableResult
    public func createPeopleGroup(name: String, memberClusterIDs: [Int]) async -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, memberClusterIDs.count >= 2 else { return nil }
        guard !peopleGroupNameExists(trimmed) else { return nil }
        let id = await store.createPeopleGroup(name: trimmed, memberClusterIDs: memberClusterIDs)
        await reloadPeopleGroups()
        return id
    }

    public func deletePeopleGroup(id: UUID) async {
        await store.deletePeopleGroup(id: id)
        await reloadPeopleGroups()
    }

    /// 名前・メンバーの更新（nil は変更しない）。メンバーを渡す場合は 2 人以上が必要。
    public func updatePeopleGroup(id: UUID, name: String? = nil,
                                  memberClusterIDs: [Int]? = nil) async {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let members = memberClusterIDs, members.count < 2 { return }
        if let trimmed, trimmed.isEmpty { return }
        // 改名でも同名は作らせない（自分自身は除く）。
        if let trimmed, peopleGroupNameExists(trimmed, excluding: id) { return }
        await store.updatePeopleGroup(id: id, name: trimmed, memberClusterIDs: memberClusterIDs)
        await reloadPeopleGroups()
    }

    /// グループの最新メンバー写真キー（アルバム表示・クラウド共有用）。
    /// ⚠️ 一覧の `PersonInfo.memberRefKeys` は遅延取得のため**空**（ADR-95）。
    /// ここでは人物ごとの取得 API（束ね人物も展開する）を使って合成する。
    public func memberRefKeys(forGroup id: UUID) async -> [String] {
        let records = await store.allPeopleGroupRecords()
        guard let record = records.first(where: { $0.id == id }) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for clusterID in record.memberClusterIDs {
            for key in await memberRefKeys(forPerson: clusterID) where seen.insert(key).inserted {
                out.append(key)
            }
        }
        return out
    }
}
