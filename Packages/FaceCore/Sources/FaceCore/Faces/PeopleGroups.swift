import Foundation
import MosaicSupport
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

    /// **現在の人物一覧に解決できなかった**メンバーの clusterID（記録順）。
    ///
    /// ⚠️ ここが本項の要（dataLoss の可視化）。以前は `compactMap` で**黙って落として**いた。
    /// 落ちる原因は「再クラスタで ID が振り直された」「パイプライン版を上げて再スキャンした」で、
    /// どちらも**利用者から見ると家族グループから人が消える**。無音だと、直したあとも
    /// 効いているか分からない——数えて記録に残す。
    public let unresolvedClusterIDs: [Int]

    public var photoCount: Int { memberRefKeys.count }

    public init(id: UUID, name: String, memberClusterIDs: [Int],
                members: [PersonInfo], memberRefKeys: [String], createdAt: Date,
                unresolvedClusterIDs: [Int] = []) {
        self.id = id
        self.name = name
        self.memberClusterIDs = memberClusterIDs
        self.members = members
        self.memberRefKeys = memberRefKeys
        self.createdAt = createdAt
        self.unresolvedClusterIDs = unresolvedClusterIDs
    }

    /// 記録メンバーと現在の人物一覧から解決済み Info を作る（純ロジック・テスト対象）。
    /// 現在の一覧に居ない clusterID（再クラスタで消えた等）は表示から外すが記録には残す。
    public static func resolve(id: UUID, name: String, memberClusterIDs: [Int],
                               createdAt: Date, people: [PersonInfo]) -> PeopleGroupInfo {
        // ⚠️ **代表クラスタだけで引かない**（ADR-232）。グループは代表 clusterID を持つが、
        // 代表は束ねの中で入れ替わる（別のクラスタに名前が付く・枚数が変わる・再スキャンで
        // 並びが変わる）。入れ替わった瞬間に、その人が家族グループから消えていた。
        var byCluster: [Int: PersonInfo] = [:]
        for person in people {
            byCluster[person.clusterID] = person
            for id in person.clusterIDs where byCluster[id] == nil { byCluster[id] = person }
        }
        // 同じ人物を 2 回入れない（構成クラスタが 2 つ記録に載っている場合）。
        var seenClusters = Set<Int>()
        let members = memberClusterIDs.compactMap { id -> PersonInfo? in
            guard let person = byCluster[id] else { return nil }
            return seenClusters.insert(person.clusterID).inserted ? person : nil
        }
        // ⚠️ **落ちたメンバーを数える**（無音をやめる）。`compactMap` は解決できない ID を
        // 黙って捨てるので、家族グループから人が消えても誰も気づけなかった。
        let unresolved = memberClusterIDs.filter { byCluster[$0] == nil }
        var seen = Set<String>()
        var refKeys: [String] = []
        for member in members {
            for key in member.memberRefKeys where seen.insert(key).inserted {
                refKeys.append(key)
            }
        }
        return PeopleGroupInfo(id: id, name: name, memberClusterIDs: memberClusterIDs,
                               members: members, memberRefKeys: refKeys, createdAt: createdAt,
                               unresolvedClusterIDs: unresolved)
    }
}

/// グループのメンバー選択の判定（純ロジック・テスト対象・ADR-232）。
///
/// ⚠️ グループの記録は人物を **clusterID（代表クラスタ）** で指しているが、代表は
/// 「名前つき → 写真の多い順 → ID 昇順」で**そのとき決まる**ので、束ねの中で入れ替わる。
/// `PeopleGroupInfo.resolve` は構成クラスタのどれでも引けるようにしたので、
/// **編集画面も同じ見方をしないと食い違う**——アルバムには出ているのに編集画面では
/// チェックが付いておらず、「直そう」として押すと同じ人物が 2 回記録に入る。
///
/// ⚠️ UI ではなくここ（ロジック層）に置く。判定は `PersonInfo` と ID 集合だけで決まり、
/// SwiftUI に依存しない——UI 層に置くと macOS の `swift test` から見えず、
/// `#if canImport(UIKit)` の内側で**テストが 1 度も走らない**ことになる。
public enum PeopleGroupSelection {

    /// その人物を指す可能性のある clusterID すべて（代表＋束ねの構成クラスタ）。
    public static func ids(of person: PersonInfo) -> Set<Int> {
        Set(person.clusterIDs + [person.clusterID])
    }

    /// 記録（選択集合）がその人物を指しているか。
    public static func isSelected(_ person: PersonInfo, in selected: Set<Int>) -> Bool {
        !ids(of: person).isDisjoint(with: selected)
    }

    /// 選択集合が指している**人物の数**（記録に同じ人物の ID が 2 つ入っていても 1 人と数える）。
    /// 「2 人以上」を ID の数で見ると、1 人を 2 通りで指しただけで作成できてしまう。
    public static func personCount(in selected: Set<Int>, among people: [PersonInfo]) -> Int {
        people.reduce(into: 0) { $0 += isSelected($1, in: selected) ? 1 : 0 }
    }

    /// 編集画面に出す人の一覧（表示フロアで隠した人のうち、**既にメンバーの人は必ず出す**）。
    ///
    /// ⚠️ `shown`（= `PeopleEngine.people`）は「ピープルに載せるか」だけの線
    /// （ADR-125・無名でフロア未満を隠す）。メンバーの写真が減ってフロアを割ると、その人は
    /// 一覧から消えて**外せなくなる**——見えない・触れないメンバーがグループに居座る。
    /// 無名のメンバーを守るようにした（ADR-231）ぶん、この状態は起きやすい。
    /// - Parameters:
    ///   - shown: 通常出す人（表示フロア適用済み）。
    ///   - all: 全員（`PeopleEngine.allPeople`）。
    ///   - selected: いま選ばれている clusterID の集合。
    public static func selectable(shown: [PersonInfo], all: [PersonInfo],
                                 selected: Set<Int>) -> [PersonInfo] {
        let shownIDs = Set(shown.map(\.clusterID))
        return shown + all.filter {
            !shownIDs.contains($0.clusterID) && isSelected($0, in: selected)
        }
    }
}

// MARK: - FaceStore CRUD

extension FaceStore {

    func allPeopleGroupRecords() -> [(id: UUID, name: String, memberClusterIDs: [Int], createdAt: Date)] {
        let records = (try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]))) ?? []
        return records.map { ($0.id, $0.name, $0.memberClusterIDs, $0.createdAt) }
    }

    /// 全グループのメンバー clusterID（種の判定用・ADR-231）。
    ///
    /// ⚠️ **1 回で読む**。再クラスタは人物ごとに引き直してはいけない（1,316 人＝1,316 往復・
    /// ADR-119）。グループは数個なので、集合にして `contains` で引く。
    func peopleGroupMemberClusterIDs() -> Set<Int> {
        let records = (countedFetchOptional(FetchDescriptor<PeopleGroupRecord>())) ?? []
        var out = Set<Int>()
        for record in records { out.formUnion(record.memberClusterIDs) }
        return out
    }

    /// 人物の統合でメンバーの clusterID が変わったとき、グループの参照を付け替える。
    ///
    /// ⚠️ グループは clusterID で人物を指しているので、統合で消えた ID を残すと
    /// **家族グループからその人が黙って消える**（`resolve` が現存しないメンバーを落とす）。
    /// `to` が既にメンバーなら `from` を取り除くだけ（同じ人物を 2 回入れない）。
    /// - Returns: 触ったグループの数。
    @discardableResult
    func remapPeopleGroups(from srcID: Int, to dstID: Int) -> Int {
        let records = (countedFetchOptional(FetchDescriptor<PeopleGroupRecord>())) ?? []
        var touched = 0
        for record in records where record.memberClusterIDs.contains(srcID) {
            var ids = record.memberClusterIDs.map { $0 == srcID ? dstID : $0 }
            // 付け替えで重複したら 1 つに畳む（順序は保つ）。
            var seen = Set<Int>()
            ids = ids.filter { seen.insert($0).inserted }
            record.memberClusterIDs = ids
            touched += 1
        }
        return touched
    }

    /// 世代の切り替えで**グループの器だけ**を新しいコンテナへ持ち込む（ADR-232）。
    /// メンバーは持ち越し（`reapplyAssertions`）が写真の重なりで埋めるので、ここでは空で作る。
    /// id と作成日時を引き継ぐ（グループの同一性は UUID で、世代を跨いで変わらない）。
    /// 同じ id が既にあれば名前だけ合わせる（何度呼んでも増えない）。
    func importPeopleGroupShell(id: UUID, name: String, createdAt: Date) {
        let groupID = id
        if let existing = try? modelContext.fetch(FetchDescriptor<PeopleGroupRecord>(
            predicate: #Predicate { $0.id == groupID })).first {
            existing.name = name
        } else {
            modelContext.insert(PeopleGroupRecord(id: id, name: name,
                                                  memberClusterIDs: [], createdAt: createdAt))
        }
        try? modelContext.save()
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
        // ⚠️ **全件**で解決する（表示フロアで隠した人物もグループの members には要る）。
        // 表示フロアは「一覧に出すか」だけの線で、内部の解決の母数は変えない。
        let current = allPeople
        peopleGroups = records.map {
            PeopleGroupInfo.resolve(id: $0.id, name: $0.name,
                                    memberClusterIDs: $0.memberClusterIDs,
                                    createdAt: $0.createdAt, people: current)
        }
        reportUnresolvedGroupMembers(peopleAvailable: !current.isEmpty)
    }

    /// 解決できなかったメンバーを診断ログへ出す（dataLoss の可視化・ADR-231）。
    ///
    /// 「家族グループから人が黙って消える」は利用者には気づきにくく、こちらからも無音だった。
    /// 出たら原因は 2 つ——再クラスタで ID が振り直された（種にならなかった）か、
    /// パイプライン版を上げて再スキャンした（持ち越しに載っていなかった）。
    ///
    /// ⚠️ **人物一覧が空のうちは黙る**（起動直後・再スキャン中は全メンバーが未解決に見える）。
    /// ⚠️ **同じ内容は 1 回だけ書く**（レビュー指摘）。`reloadPeopleGroups` は `loadPeople` から
    /// 呼ばれ、実機では**毎分 30 回**走る。診断ログは末尾 256KB しか残らないので、
    /// 解決できないメンバーが 1 人でも居座ると——写真を消したなど、二度と一致しない場合は
    /// まさにそうなる——**同じ行で記録を埋め尽くし、残したかった証拠を押し出してしまう**。
    /// 中身（どのグループが何人）が変わったときだけ書く。
    private func reportUnresolvedGroupMembers(peopleAvailable: Bool) {
        guard peopleAvailable else { return }
        let lost = peopleGroups.filter { !$0.unresolvedClusterIDs.isEmpty }
        let signature = lost
            .map { "\($0.id.uuidString):\($0.unresolvedClusterIDs.sorted().map(String.init).joined(separator: ","))" }
            .sorted().joined(separator: "|")
        guard signature != lastUnresolvedGroupSignature else { return }
        lastUnresolvedGroupSignature = signature
        guard !lost.isEmpty else { return }   // 直った（＝空になった）ことも覚えるが書かない
        let detail = lost.map { "\($0.name):\($0.unresolvedClusterIDs.count)" }
            .joined(separator: " ")
        Diagnostics.mark("peopleGroups: unresolved members — \(detail) "
                         + "(再クラスタで ID が変わった／再スキャンで持ち越せなかった)")
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
