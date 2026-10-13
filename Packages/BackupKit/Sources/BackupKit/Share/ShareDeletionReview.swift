import Foundation

/// **消す前に確かめる**（ADR-278・純ロジック）。
///
/// ## なぜ要るか
/// 差分方式（ADR-209）の削除は「実在 − 望ましい」で、**望ましい集合の材料が全部そろっている**
/// ことを前提にしている。ところが材料は「読めた」のに**中身が欠けている**ことがある:
/// - バックアップ記録が照合で消えた（Backup のファイルが Dropbox から消えた）
///   ——オフロード済みの写真では、**共有コピーが最後の 1 枚**のことがある。
/// - クラウド写真の content_hash がまだ分からない回（印が別の名前になる）。
/// - 写真を編集して中身が変わった回に、新しいコピーが失敗した。
/// どれも「望ましくない」と読まれて消えていた。消す理由は**引き算の結果**でしかなく、
/// 誰も「消してよいか」を確かめていなかった。
///
/// ## 決め方
/// 消す候補 1 つずつに、**消す理由**と**中身の行き先**を確かめる。
/// 1. 同じ中身が、このフォルダに望ましいファイルとして在る → 消してよい（中身は残る）。
/// 2. いまのメンバーのコピー（印から引き当てる）:
///    - メンバーがまだ解決できない／新しいコピーがまだ無い → **触らない**。
///    - 新しいコピーが在る（古い版）→ 3 へ。
/// 3. 中身が Dropbox の**他の場所**に在るかを確かめる（`Evidence`）:
///    在る → 消す／どこにも無い → **退避**（`ShareRemoved` へ移す）／分からない → この回は触らない。
///
/// ⚠️ 「分からない」を「無い」と読まない（ADR-277 と同じ形）。退避も書き込みなので、
/// 確かめきれなかった回は**何もしない**。
public enum ShareDeletionReview {

    /// 消す候補 1 つの扱い。
    public enum Verdict: Equatable, Sendable {
        /// 同じ中身が、このフォルダの望ましいファイルとして在る。消しても中身は残る。
        case duplicateOfPresent
        /// いまのメンバーのコピー。置き換え先がまだ無い／メンバーがまだ解決できない。
        case keptForMember(refKey: String)
        /// 中身が他に在るかを確かめてから決める。`ownerRefKey` は古い版の持ち主（無ければ nil）。
        case needsEvidence(ownerRefKey: String?)
        /// この回は照合しきれない（上限）。触らない。
        case deferred
    }

    /// 中身が Dropbox の他の場所に在るか。
    public enum Evidence: Equatable, Sendable {
        case foundElsewhere
        case absentEverywhere
        /// 確かめきれなかった（通信の失敗・上限）。
        case unknown
    }

    /// 候補に対してやること。
    public enum Action: Equatable, Sendable {
        case delete
        case moveToHolding
        case leave
    }

    /// 印の照合に使う SHA-256 の計算回数の上限（1 回の反映あたり）。
    /// メンバー 12,941 枚 × 候補の中身の種類なので、候補が多い回は続きを次の回へ回す。
    public static let identityHashBudget = 2_000_000

    /// 候補を分類する。
    /// - Parameters:
    ///   - candidates: 消す候補（`SharePlanning.Plan.deletions` に当たる実在ファイル）。
    ///   - members: いまのメンバーの refKey（解決できたかどうかに関わらず全員）。
    ///   - destinationByRefKey: 解決できたメンバー → 望ましい宛先（小文字）。
    ///   - presentAfterCopy: この回のコピーの後に在る宛先（小文字）。
    ///   - presentHashes: このフォルダに望ましいファイルとして在る中身。
    public static func classify(candidates: [SharePlanning.RemoteFile],
                                members: [String],
                                destinationByRefKey: [String: String],
                                presentAfterCopy: Set<String>,
                                presentHashes: Set<String>,
                                hashBudget: Int = identityHashBudget) -> [String: Verdict] {
        var verdicts: [String: Verdict] = [:]
        let sortedMembers = Array(Set(members)).sorted()
        var spent = 0
        // 中身が分からない名前（content_hash 不明で組んだ印）は 1 回だけ作る。
        var hashlessIdentity: [String: String]?
        // 中身 → (印 → refKey)。候補の中身ごとに 1 回だけ作る。
        var identitiesByHash: [String: [String: String]] = [:]

        for candidate in candidates.sorted(by: { $0.pathLower < $1.pathLower }) {
            if let hash = candidate.contentHash, !hash.isEmpty, presentHashes.contains(hash) {
                verdicts[candidate.pathLower] = .duplicateOfPresent
                continue
            }
            let filename = (candidate.pathLower as NSString).lastPathComponent
            guard let tail = ShareNaming.identityTail(of: filename) else {
                // 印の無い名前（旧方式のコピー・家族が置いたファイル）＝持ち主は引けない。
                verdicts[candidate.pathLower] = .needsEvidence(ownerRefKey: nil)
                continue
            }
            if hashlessIdentity == nil {
                guard spent + sortedMembers.count <= hashBudget else {
                    verdicts[candidate.pathLower] = .deferred
                    continue
                }
                spent += sortedMembers.count
                hashlessIdentity = identityTable(members: sortedMembers, contentHash: nil)
            }
            var owner = hashlessIdentity?[tail]
            if owner == nil, let hash = candidate.contentHash, !hash.isEmpty {
                if identitiesByHash[hash] == nil {
                    guard spent + sortedMembers.count <= hashBudget else {
                        verdicts[candidate.pathLower] = .deferred
                        continue
                    }
                    spent += sortedMembers.count
                    identitiesByHash[hash] = identityTable(members: sortedMembers, contentHash: hash)
                }
                owner = identitiesByHash[hash]?[tail]
            }
            guard let owner else {
                verdicts[candidate.pathLower] = .needsEvidence(ownerRefKey: nil)
                continue
            }
            if let destination = destinationByRefKey[owner], presentAfterCopy.contains(destination) {
                verdicts[candidate.pathLower] = .needsEvidence(ownerRefKey: owner)   // 古い版
            } else {
                verdicts[candidate.pathLower] = .keptForMember(refKey: owner)
            }
        }
        return verdicts
    }

    private static func identityTable(members: [String], contentHash: String?) -> [String: String] {
        var table: [String: String] = [:]
        for refKey in members {
            table[ShareNaming.identity(refKey: refKey, contentHash: contentHash)] = refKey
        }
        return table
    }

    /// 分類と実物の確認から、やることを決める。
    public static func action(for verdict: Verdict, evidence: Evidence?) -> Action {
        switch verdict {
        case .duplicateOfPresent:
            return .delete
        case .keptForMember, .deferred:
            return .leave
        case .needsEvidence:
            switch evidence {
            case .foundElsewhere: return .delete
            case .absentEverywhere: return .moveToHolding
            case .unknown, nil: return .leave
            }
        }
    }

    // MARK: - 実物の確認（どこを見るか）

    /// 中身 → それが在るはずの場所（パス小文字）。
    ///
    /// 材料は「バックアップ記録」と「クラウドの同期一覧」の 2 つ。⚠️ **どちらも Dropbox の今の姿ではない**
    /// （記録は照合の時点、同期一覧は差分の時点）ので、ここで挙げた場所は `verificationPlan` で
    /// 実際に問い合わせて確かめる。
    /// ⚠️ **共有のコピーは証拠にしない**（このアプリが置いた名前・共有ルートと退避先の下）。
    /// 2 台がお互いの共有コピーを「他に在る」と数えると、両方が消して中身が無くなる。
    public static func locations(for hashes: Set<String>,
                                 records: [(path: String, hash: String)],
                                 cloud: [String: String],
                                 excludingPrefixes: [String]) -> [String: [String]] {
        let prefixes = excludingPrefixes.map { $0.lowercased().hasSuffix("/") ? $0.lowercased()
                                                                              : $0.lowercased() + "/" }
        func admissible(_ path: String) -> Bool {
            let lower = path.lowercased()
            if prefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            return !ShareNaming.isShareManagedFileName((lower as NSString).lastPathComponent)
        }
        var out: [String: Set<String>] = [:]
        for record in records where hashes.contains(record.hash) && admissible(record.path) {
            out[record.hash, default: []].insert(record.path.lowercased())
        }
        for (path, hash) in cloud where hashes.contains(hash) && admissible(path) {
            out[hash, default: []].insert(path.lowercased())
        }
        return out.mapValues { $0.sorted() }
    }

    /// 確かめ方。親フォルダごとにまとめ、多ければ一覧 1 回、少なければ 1 件ずつ訊く。
    public struct VerificationPlan: Equatable, Sendable {
        /// 一覧を取るフォルダ（小文字）。
        public var listFolders: [String] = []
        /// 1 件ずつ `get_metadata` で訊くパス（小文字）。
        public var metadataPaths: [String] = []
    }

    /// 1 つの親フォルダにこの数以上の場所があれば、1 件ずつ訊かずに一覧を取る。
    public static let listThreshold = 20
    /// 1 回の反映で確かめに使う往復の上限。超えた分は「分からない」（次の回へ）。
    public static let maxVerificationRequests = 200

    public static func verificationPlan(locations: [String: [String]],
                                        maxRequests: Int = maxVerificationRequests) -> VerificationPlan {
        var byParent: [String: Set<String>] = [:]
        for path in locations.values.joined() {
            byParent[(path as NSString).deletingLastPathComponent, default: []].insert(path)
        }
        var plan = VerificationPlan()
        var requests = 0
        for parent in byParent.keys.sorted() {
            let paths = byParent[parent]!.sorted()
            if paths.count >= listThreshold {
                guard requests + 1 <= maxRequests else { break }
                requests += 1
                plan.listFolders.append(parent)
            } else {
                guard requests + paths.count <= maxRequests else { break }
                requests += paths.count
                plan.metadataPaths.append(contentsOf: paths)
            }
        }
        return plan
    }

    /// 1 か所を訊いた答え。
    public enum Lookup: Equatable, Sendable {
        case file(contentHash: String?)
        case notFound
        case failed
    }

    /// 訊いた答えから、中身ごとの証拠を決める。
    /// - Parameter answers: 場所（小文字）→ 答え。**訊いていない場所は入れない**（＝分からない）。
    public static func evidence(for hash: String,
                                locations: [String: [String]],
                                answers: [String: Lookup]) -> Evidence {
        let places = locations[hash] ?? []
        guard !places.isEmpty else { return .absentEverywhere }
        var undecided = false
        for place in places {
            switch answers[place] {
            case .file(let found) where found == hash:
                return .foundElsewhere
            case .file, .notFound:
                continue
            case .failed, nil:
                undecided = true
            }
        }
        return undecided ? .unknown : .absentEverywhere
    }
}
