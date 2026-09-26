import Foundation
import MosaicSupport
import SwiftData

/// **ユーザーが表明したものの国勢調査**（ADR-233・純ロジック・テスト対象）。
///
/// ## なぜ要るか
/// 顔まわりの不具合は、ほぼ全部が同じ形で出る——**利用者が手で作ったもの（名前・束ね・家族
/// グループ・確認顔）が、機械の都合で黙って消える**。そして消えるのは**遷移のとき**だけ:
/// 夜の再クラスタ、版上げの再スキャン、モデル世代の切り替え、写真の整理。
///
/// ⚠️ 定常状態では 1 つも出ない。つまり**「使っていれば気づく」が成り立たない**。
/// ライブラリの解析が終わって新しい写真が流れなくなり、誤認識も出なくなると、
/// 遷移を通る機会そのものが年に数回になる——そのとき壊れていても、誰も見ていない。
///
/// だから「調べに行く」のではなく **遷移の前後を毎回突き合わせて、減ったら記録に残す**。
/// ADR-144 が名前付き人物の**写真の枚数**についてやっていたことを、**表明の全部**に広げる。
///
/// ## ⚠️ 数だけでは足りない
/// 「別人が居座る」は**数が減らない**（家族グループのメンバー数は 2 のまま、中身が別人）。
/// 実際にその不具合を踏んだ（clusterID が振り直されたのに記録が古い ID を指していた）。
/// なので**同じ ID が同じ人を指しているか**＝メンバーの写真が入れ替わっていないかも見る。
public struct AssertionCensus: Sendable, Equatable {

    /// 人物 1 人ぶんの表明（clusterID をキーに突き合わせる）。
    public struct Person: Sendable, Equatable {
        public let clusterID: Int
        public let name: String?
        /// 束ねの札（ADR-61）。
        public let personGroupID: Int?
        /// 代表写真を選んでいるか。
        public let hasCover: Bool
        /// 「この顔はこの人」と確認した顔の数（ADR-46）。
        public let confirmedFaces: Int
        /// この人物の写真（refKey）。**入れ替わりの検出に使う**ので、数ではなく集合で持つ。
        public let refKeys: Set<String>

        public init(clusterID: Int, name: String? = nil, personGroupID: Int? = nil,
                    hasCover: Bool = false, confirmedFaces: Int = 0,
                    refKeys: Set<String> = []) {
            self.clusterID = clusterID
            self.name = name
            self.personGroupID = personGroupID
            self.hasCover = hasCover
            self.confirmedFaces = confirmedFaces
            self.refKeys = refKeys
        }

        var isNamed: Bool { name?.isEmpty == false }
    }

    /// 家族グループ 1 つぶん。
    public struct Group: Sendable, Equatable {
        public let id: UUID
        public let name: String
        /// 記録上のメンバー clusterID（**順序も含めてそのまま**）。
        public let memberClusterIDs: [Int]

        public init(id: UUID, name: String, memberClusterIDs: [Int]) {
            self.id = id
            self.name = name
            self.memberClusterIDs = memberClusterIDs
        }
    }

    public let people: [Person]
    public let groups: [Group]

    public init(people: [Person], groups: [Group]) {
        self.people = people
        self.groups = groups
    }

    // MARK: - 集計（ログの 1 行目に出す数）

    public var namedCount: Int { people.filter(\.isNamed).count }
    public var bundleCount: Int { Set(people.compactMap(\.personGroupID)).count }
    public var coverCount: Int { people.filter(\.hasCover).count }
    public var confirmedCount: Int { people.reduce(0) { $0 + $1.confirmedFaces } }
    /// グループのメンバーのうち、**実際に人物として在るもの**の数（記録上の数ではない）。
    public var resolvedGroupMemberCount: Int {
        let live = Set(people.map(\.clusterID))
        return groups.reduce(0) { $0 + $1.memberClusterIDs.filter(live.contains).count }
    }

    // MARK: - 突き合わせ

    /// 見つかったこと 1 件。
    public struct Finding: Sendable, Equatable {
        public enum Kind: String, Sendable {
            /// 名前が消えた（行ごと消えた／名前だけ抜けた）。
            case nameLost
            /// 束ねがほどけた（札が消えた・別の札に混ざった、ではなく**無くなった**）。
            case bundleLost
            /// 代表写真の指定が消えた。
            case coverLost
            /// 確認顔が減った。
            case confirmationsLost
            /// 家族グループのメンバーが（人物として）解決できなくなった。
            case groupMemberLost
            /// ⚠️ **同じ ID が別人を指すようになった**（数は減らないので、これだけは集合で見る）。
            case groupMemberSwapped
            /// 家族グループの行ごと消えた。
            case groupLost
        }
        public let kind: Kind
        /// 人に読める対象（人物名 or グループ名 or "cluster N"）。
        public let subject: String
        /// 追加の説明（数の前後など）。
        public let detail: String

        public init(kind: Kind, subject: String, detail: String = "") {
            self.kind = kind
            self.subject = subject
            self.detail = detail
        }
    }

    /// 遷移の前後を突き合わせる。
    ///
    /// ⚠️ **増えたことは報告しない**。再スキャンで人物が増えるのは正常で、報告すると本当の
    /// 損失が埋もれる（`peopleGroups: unresolved members` が毎分 30 回出て 256KB の記録を
    /// 押し流した件と同じ形）。見るのは**減った／入れ替わった**ことだけ。
    ///
    /// ⚠️ **突き合わせの鍵は写真（refKey）**にする。clusterID は遷移で振り直されるので、
    /// ID で突き合わせると「全員消えた」になる。写真は再スキャンしても変わらない（ADR-51）。
    /// - Parameter swapOverlap: 「同じ人」と認める写真の重なりの割合（既定 0.2）。
    ///   下回ったら**入れ替わった**とみなす。
    public static func diff(before: AssertionCensus, after: AssertionCensus,
                           swapOverlap: Double = 0.2) -> [Finding] {
        var findings: [Finding] = []
        let afterByID = Dictionary(after.people.map { ($0.clusterID, $0) }, uniquingKeysWith: { a, _ in a })

        // --- 人物ごとの表明 ---
        for old in before.people {
            // 写真の重なりで「移った先」を探す（ID は当てにできない）。
            let successor = bestSuccessor(of: old, in: after.people, minOverlap: swapOverlap)
            let label = old.name ?? "cluster \(old.clusterID)"
            if old.isNamed, successor?.isNamed != true {
                findings.append(.init(kind: .nameLost, subject: label,
                                      detail: successor == nil ? "人物ごと消えた" : "名前だけ抜けた"))
            }
            if old.personGroupID != nil, successor?.personGroupID == nil {
                findings.append(.init(kind: .bundleLost, subject: label))
            }
            if old.hasCover, successor?.hasCover != true {
                findings.append(.init(kind: .coverLost, subject: label))
            }
            if old.confirmedFaces > 0, (successor?.confirmedFaces ?? 0) < old.confirmedFaces {
                findings.append(.init(kind: .confirmationsLost, subject: label,
                                      detail: "\(old.confirmedFaces)→\(successor?.confirmedFaces ?? 0)"))
            }
        }

        // --- 家族グループ ---
        let afterGroups = Dictionary(after.groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let liveAfter = Set(after.people.map(\.clusterID))
        let beforePeopleByID = Dictionary(before.people.map { ($0.clusterID, $0) },
                                         uniquingKeysWith: { a, _ in a })
        for oldGroup in before.groups {
            guard let newGroup = afterGroups[oldGroup.id] else {
                findings.append(.init(kind: .groupLost, subject: oldGroup.name))
                continue
            }
            // 解決できなくなったメンバー（記録に残っていても人物として居ない）。
            let lost = newGroup.memberClusterIDs.filter { !liveAfter.contains($0) }
            let vanished = oldGroup.memberClusterIDs.filter { !newGroup.memberClusterIDs.contains($0) }
            if !lost.isEmpty || !vanished.isEmpty {
                findings.append(.init(
                    kind: .groupMemberLost, subject: oldGroup.name,
                    detail: "解決できない \(lost.count)・記録から消えた \(vanished.count)"))
            }
            // ⚠️ **数が同じでも中身が別人**を捕まえる。前は在って後も在る ID について、
            // その人物の写真が入れ替わっていたら「別人が居座った」。
            for id in newGroup.memberClusterIDs {
                guard let oldPerson = beforePeopleByID[id], let newPerson = afterByID[id] else { continue }
                guard !oldPerson.refKeys.isEmpty, !newPerson.refKeys.isEmpty else { continue }
                let shared = oldPerson.refKeys.intersection(newPerson.refKeys).count
                let ratio = Double(shared) / Double(min(oldPerson.refKeys.count, newPerson.refKeys.count))
                if ratio < swapOverlap {
                    findings.append(.init(
                        kind: .groupMemberSwapped, subject: oldGroup.name,
                        detail: "cluster \(id) の写真が入れ替わった（共通 \(shared) 枚）"))
                }
            }
        }
        return findings
    }

    /// 写真の重なりが最大の「移った先」（足切り未満なら nil＝消えたとみなす）。
    private static func bestSuccessor(of old: Person, in after: [Person],
                                     minOverlap: Double) -> Person? {
        guard !old.refKeys.isEmpty else {
            // 写真が 0 枚の人物は重なりで追えないので、ID で見るしかない。
            return after.first { $0.clusterID == old.clusterID }
        }
        var best: (Person, Int)?
        for candidate in after {
            let shared = old.refKeys.intersection(candidate.refKeys).count
            if shared > 0, shared > (best?.1 ?? 0) { best = (candidate, shared) }
        }
        guard let (person, shared) = best,
              Double(shared) / Double(old.refKeys.count) >= minOverlap else { return nil }
        return person
    }

    /// 診断ログ 1 行にまとめる（数の前後）。
    public static func summary(before: AssertionCensus, after: AssertionCensus) -> String {
        func pair(_ a: Int, _ b: Int) -> String { a == b ? "\(a)" : "\(a)→\(b)" }
        return "named=\(pair(before.namedCount, after.namedCount)) "
            + "bundles=\(pair(before.bundleCount, after.bundleCount)) "
            + "covers=\(pair(before.coverCount, after.coverCount)) "
            + "confirmed=\(pair(before.confirmedCount, after.confirmedCount)) "
            + "groupMembers=\(pair(before.resolvedGroupMemberCount, after.resolvedGroupMemberCount)) "
            + "groups=\(pair(before.groups.count, after.groups.count))"
    }
}

// MARK: - 台帳から国勢調査を取る

extension FaceStore {

    /// いまの表明を数え上げる（ADR-233）。遷移の**前後で 1 回ずつ**呼ぶ。
    ///
    /// ⚠️ **クラスタごとに引かない**（ADR-119）。必要なのは refKey と確認の有無なので、
    /// 顔は**射影クエリ 1 回**でまとめて取る（1,300 人なら 1,300 往復になっていた形）。
    /// - Parameter maxRefKeys: 1 人あたりに覚える写真の数（入れ替わりの判定に足りる分だけ）。
    func assertionCensus(maxRefKeys: Int = 200) -> AssertionCensus {
        var faceQuery = FetchDescriptor<DetectedFace>()
        faceQuery.propertiesToFetch = [\.clusterID, \.refKey, \.confirmedAt]
        var refKeys: [Int: Set<String>] = [:]
        var confirmed: [Int: Int] = [:]
        for face in (countedFetchOptional(faceQuery)) ?? [] where face.clusterID >= 0 {
            if (refKeys[face.clusterID]?.count ?? 0) < maxRefKeys {
                refKeys[face.clusterID, default: []].insert(face.refKey)
            }
            if face.confirmedAt != nil { confirmed[face.clusterID, default: 0] += 1 }
        }
        let people = allClusters().map { c in
            AssertionCensus.Person(
                clusterID: c.clusterID, name: c.name, personGroupID: c.personGroupID,
                hasCover: c.coverFaceID != nil, confirmedFaces: confirmed[c.clusterID] ?? 0,
                refKeys: refKeys[c.clusterID] ?? [])
        }
        let groups = ((countedFetchOptional(FetchDescriptor<PeopleGroupRecord>())) ?? []).map {
            AssertionCensus.Group(id: $0.id, name: $0.name, memberClusterIDs: $0.memberClusterIDs)
        }
        return AssertionCensus(people: people, groups: groups)
    }

    /// 遷移の前後を突き合わせて診断ログへ出す（ADR-233）。
    ///
    /// ⚠️ **何も減っていなくても 1 行は出す**。「出ていない」と「そもそも走っていない」を
    /// 区別できないログは、後から見たときに役に立たない（ADR-207 で同じ失敗をしている）。
    /// 減っていたときだけ、その内訳を続けて出す。
    /// - Parameter label: 何の遷移か（"rebuild" / "rescan" / "promote" / "prune"）。
    func reportAssertionCensus(_ label: String, before: AssertionCensus,
                               after: AssertionCensus? = nil) {
        let now = after ?? assertionCensus()
        Diagnostics.mark("faces: census[\(label)] "
                         + AssertionCensus.summary(before: before, after: now))
        let findings = AssertionCensus.diff(before: before, after: now)
        guard !findings.isEmpty else { return }
        // 種類ごとにまとめる（同じ種類が何十件も並ぶと 256KB の記録を押し流す）。
        var byKind: [AssertionCensus.Finding.Kind: [AssertionCensus.Finding]] = [:]
        for finding in findings { byKind[finding.kind, default: []].append(finding) }
        for (kind, items) in byKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let examples = items.prefix(3)
                .map { $0.detail.isEmpty ? $0.subject : "\($0.subject)（\($0.detail)）" }
                .joined(separator: ", ")
            Diagnostics.mark("faces: ⚠️ census[\(label)] \(kind.rawValue) ×\(items.count) — \(examples)"
                             + (items.count > 3 ? " …" : ""))
        }
    }
}
