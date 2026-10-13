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

    /// 印の照合に使う SHA-256 の計算回数の上限（1 回の反映あたり）。超えた候補は次の回へ持ち越す。
    ///
    /// ⚠️ 照合は**ファイル名の幹で絞る**（元のファイル名が分かるメンバーだけと照らす）ので、
    /// 総当たりになるのは元の名前が分からないメンバー（記録が消えた端末写真）だけ。
    /// 最初の版は全メンバー × 候補の中身ごとに表を作り、上限 200 万回をメインスレッドで回していた
    /// （外した写真 500 枚 × メンバー 12,941 枚で 1 分・表だけで数百 MB・レビュー指摘）。
    public static let identityHashBudget = 200_000

    /// 候補を分類する。**重いので MainActor から直接呼ばない**（`Task.detached` で回す）。
    /// - Parameters:
    ///   - candidates: 消す候補（`SharePlanning.Plan.deletions` に当たる実在ファイル）。
    ///   - members: いまのメンバーの refKey（解決できたかどうかに関わらず全員）。
    ///   - sourceFileNames: メンバー → 元のファイル名（分かるものだけ。幹で照合を絞る）。
    ///   - destinationByRefKey: 解決できたメンバー → 望ましい宛先（小文字）。
    ///   - presentAfterCopy: この回のコピーの後に在る宛先（小文字）。
    ///   - presentHashes: このフォルダに望ましいファイルとして在る中身。
    ///   - startOffset: 何番目の候補から見るか。**回ごとにずらす**（上限で持ち越した候補が、毎回同じ
    ///     先頭の候補に上限を食われて永久に見られない、を無くす・独立レビュー 2 回目）。
    public static func classify(candidates: [SharePlanning.RemoteFile],
                                members: [String],
                                sourceFileNames: [String: String],
                                destinationByRefKey: [String: String],
                                presentAfterCopy: Set<String>,
                                presentHashes: Set<String>,
                                startOffset: Int,
                                hashBudget: Int = identityHashBudget) -> [String: Verdict] {
        var verdicts: [String: Verdict] = [:]
        // 幹 → その幹になるメンバー。元の名前が分からないメンバーは総当たりの側へ。
        var byStem: [String: [String]] = [:]
        var unnamed: [String] = []
        for refKey in Array(Set(members)).sorted() {
            if let name = sourceFileNames[refKey] {
                byStem[stemKey(ShareNaming.sharedStem(sourceFileName: name)), default: []].append(refKey)
            } else {
                unnamed.append(refKey)
            }
        }
        var spent = 0

        let ordered = candidates.sorted(by: { $0.pathLower < $1.pathLower })
        let start = ordered.isEmpty ? 0 : ((startOffset % ordered.count) + ordered.count) % ordered.count
        for candidate in ordered[start...] + ordered[..<start] {
            if let hash = candidate.contentHash, !hash.isEmpty, presentHashes.contains(hash) {
                verdicts[candidate.pathLower] = .duplicateOfPresent
                continue
            }
            let filename = (candidate.pathLower as NSString).lastPathComponent
            guard let tail = ShareNaming.identityTail(of: filename),
                  let stem = ShareNaming.managedStem(of: filename) else {
                // 印の無い名前（旧方式のコピー・家族が置いたファイル）＝持ち主は引けない。
                verdicts[candidate.pathLower] = .needsEvidence(ownerRefKey: nil)
                continue
            }
            let hash = candidate.contentHash.flatMap { $0.isEmpty ? nil : $0 }
            func owns(_ refKey: String) -> Bool {
                spent += hash == nil ? 1 : 2
                if ShareNaming.identity(refKey: refKey, contentHash: nil) == tail { return true }
                if let hash, ShareNaming.identity(refKey: refKey, contentHash: hash) == tail { return true }
                return false
            }
            let named = byStem[stemKey(stem)] ?? []
            let cost = (named.count + unnamed.count) * (hash == nil ? 1 : 2)
            guard spent + cost <= hashBudget else {
                verdicts[candidate.pathLower] = .deferred
                continue
            }
            guard let owner = named.first(where: owns) ?? unnamed.first(where: owns) else {
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

    /// 照合に使う幹の鍵。**名前が変わる 2 つの理由を畳む**（独立レビュー 2 回目）:
    /// 編集した写真はバックアップで `<幹>-edited` に、Dropbox の自動改名で `<幹> (1)` になる。
    /// 畳まないと、上げ直しで名前が変わったメンバーの古い版が「持ち主なし」に見え、
    /// 新しい版のコピーが失敗した回に家族から消えていた。
    static func stemKey(_ stem: String) -> String {
        var key = stem.lowercased()
        while true {
            if key.hasSuffix("-edited") { key.removeLast("-edited".count); continue }
            if let range = key.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                key.removeSubrange(range); continue
            }
            return key
        }
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
    /// ⚠️ **共有のコピーは証拠にしない**。2 台がお互いの共有コピーを「他に在る」と数えると、
    /// 両方が消して中身が無くなる。共有のコピーとは:
    /// - **どの端末の** `Share` / `ShareRemoved` の下にあるもの（`layoutRoot/<端末>/Share/…`）
    ///   ⚠️ 最初の版は**この端末の**共有ルートだけを外し、他の端末の分は名前の印で見分けていた。
    ///   印の無い古いコピーや `(1)` の付いた名前は印に当たらず、証拠に数えていた（レビュー指摘）。
    /// - `excludingPrefixes` の下（旧配置の `/MosaicShare` など）
    /// - このアプリの印の付いた名前
    public static func locations(for hashes: Set<String>,
                                 records: [(path: String, hash: String)],
                                 cloud: [String: String],
                                 layoutRoot: String,
                                 excludingPrefixes: [String]) -> [String: [String]] {
        let prefixes = excludingPrefixes.map { $0.lowercased().hasSuffix("/") ? $0.lowercased()
                                                                              : $0.lowercased() + "/" }
        let root = layoutRoot.lowercased().hasSuffix("/") ? layoutRoot.lowercased() : layoutRoot.lowercased() + "/"
        let shareAreas: Set<String> = [BackupLayout.shareSubfolder.lowercased(),
                                       BackupLayout.shareRemovedSubfolder.lowercased()]
        func admissible(_ path: String) -> Bool {
            let lower = path.lowercased()
            if prefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            if lower.hasPrefix(root) {
                let parts = lower.dropFirst(root.count).split(separator: "/")
                // `<端末>/Share/…` と、端末フォルダを挟まない旧配置の `Share/…`。
                if parts.count >= 2, shareAreas.contains(String(parts[1])) { return false }
                if let first = parts.first, shareAreas.contains(String(first)) { return false }
            }
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

    /// - Parameter listableRoot: **一覧を取ってよいフォルダの根**（自分のバックアップの配置＝月ごとのフォルダで、
    ///   大きさに上限がある）。それ以外（クラウドの「カメラアップロード」など 10 万件のフォルダ）は一覧せず
    ///   1 件ずつ訊く（独立レビュー 4 回目: 1 回の確認で 10 万件を数十秒かけて一覧し、毎回やり直していた）。
    public static func verificationPlan(locations: [String: [String]],
                                        listableRoot: String,
                                        startOffset: Int,
                                        maxRequests: Int = maxVerificationRequests) -> VerificationPlan {
        let root = listableRoot.lowercased().hasSuffix("/") ? listableRoot.lowercased() : listableRoot.lowercased() + "/"
        var byParent: [String: Set<String>] = [:]
        for path in locations.values.joined() {
            byParent[(path as NSString).deletingLastPathComponent, default: []].insert(path)
        }
        var plan = VerificationPlan()
        var requests = 0
        // 回ごとに始める親をずらす（上限で、いつも同じ親だけが確かめられることを無くす）。
        let parents = byParent.keys.sorted()
        let begin = parents.isEmpty ? 0 : (startOffset % parents.count + parents.count) % parents.count
        for parent in parents[begin...] + parents[..<begin] {
            let paths = byParent[parent]!.sorted()
            if paths.count >= listThreshold, (parent + "/").hasPrefix(root) {
                guard requests + 1 <= maxRequests else { break }
                requests += 1
                plan.listFolders.append(parent)
            } else {
                // ⚠️ 入りきらない親も**入るだけ**訊く（丸ごと飛ばすと、200 を超える親は永久に確かめられない
                // ・独立レビュー 5 回目）。上限に達したら止める。
                let room = maxRequests - requests
                guard room > 0 else { break }
                let taken = Array(paths.prefix(room))
                requests += taken.count
                plan.metadataPaths.append(contentsOf: taken)
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
