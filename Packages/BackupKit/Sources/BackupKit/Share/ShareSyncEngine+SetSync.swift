import DropboxCore
import Foundation
import MosaicSupport

// MARK: - 1 セットぶんの反映（ADR-209 / ADR-278）
//
// `sync(set:)` は以前 1 関数（約 220 行・分岐 43＝リポジトリ最大）で、読む・計画する・印を片付ける・
// 消す前の確認・コピー・解析データを全部やっていた。ここでは手順を段に分け、本体は段を並べるだけにする。
// ⚠️ 段の**順番に意味がある**（各段のコメント）。並べ替えるときは本体のコメントを読むこと。
//
// ```
// 準備（メンバーを読む・フォルダを用意する）→ 原本の中身を少し訊く → 計画（純ロジック）→ 印
//   → 解析データ（いま置かれている分）→ コピー → 消す前の確認 → 掃除 → 数を控える → 解析データ（コピー分）
// ```

extension ShareSyncEngine {

    func sync(set: ShareSetLite, shareRoot: String, store: BackupStore,
              copier: DropboxShareCopier, token: String, remote: RemoteShareIndex,
              removal: RemovalContext) async {
        guard let prepared = await prepareSet(set, shareRoot: shareRoot, store: store,
                                              copier: copier, token: token, remote: remote) else { return }
        let items = prepared.items
        let setFolder = prepared.setFolder
        let remoteFiles = prepared.remoteFiles

        // 計画（純ロジック）: 望ましい集合と実在の差分。
        let localIDs = items.filter { $0.refKey.hasPrefix("L-") }
            .map { String($0.refKey.dropFirst(2)) }
        guard let backupRefs = await store.readBackupRefs(forLocalIdentifiers: localIDs) else {
            Diagnostics.mark("share sync: '\(set.name)' のバックアップ記録が読めない — この回は見送る")
            return
        }
        let cloudHashes = await resolveCloudHashes(items: items, known: removal.cloudHashes,
                                                   copier: copier, token: token)
        // 覚えた中身は、消す前の確認の証拠にも使う（原本が在るのに「どこにも無い」と読まない）。
        let removal = RemovalContext(layoutRoot: removal.layoutRoot, shareRoot: removal.shareRoot,
                                     holdingRoot: removal.holdingRoot, cloudHashes: cloudHashes,
                                     store: removal.store, copier: removal.copier, token: removal.token)
        let plan = SharePlanning.plan(items: items, backupByLocalID: backupRefs,
                                      cloudHashByPath: cloudHashes,
                                      setFolder: setFolder, remoteFiles: remoteFiles)
        reportPlan(plan, set: set, items: items)

        // ⚠️ 止まった回は、ここから先（解析データ・コピー・掃除）をしない（`stopAtNextBreak`）。
        if shouldStopAtBreak {
            await store.recordShareSyncCounts(setID: set.id, present: plan.present,
                                              waiting: plan.waitingBackup.count)
            return
        }
        // 解析データは**コピーの前に**、いま置かれている分で揃える（ADR-183）。
        // コピーは数分かかるので、後回しだと「反映を押しても解析データが何分も更新されない」。
        let presentPaths = Set(remoteFiles.map(\.pathLower))
            .subtracting(plan.deletions)
        reviewRotation &+= 1
        let review = ShareSetReview(plan: plan, items: items, remoteFiles: remoteFiles,
                                    presentPaths: presentPaths, rotation: reviewRotation)
        let early = review.analysisInputs(present: presentPaths,
                                          verdicts: await review.classify(presentAfterCopy: presentPaths))
        await updateAnalysisData(set: set, setFolder: setFolder, items: items,
                                 presentPathsLower: early.present, sourceByRefKey: early.sources,
                                 copier: copier, token: token,
                                 remoteAnalysisFiles: remote.analysisFiles(inSetFolder: setFolder))

        let (copied, copiedDestinations) = await copyPlanned(plan, set: set, copier: copier, token: token)
        // ⚠️ 止まった回は**消さない**（`stopAtNextBreak`）。数えた分だけ控えて抜ける。
        if shouldStopAtBreak {
            await store.recordShareSyncCounts(setID: set.id, present: plan.present + copied,
                                              waiting: plan.waitingBackup.count)
            return
        }

        // 掃除。⚠️ **消す前に、消す理由と中身の行き先を確かめる**（ADR-278）。
        // 以前は「望ましくない」＝引き算の結果をそのまま消していた（ADR-209）。材料が欠けた回
        // （記録が照合で消えた・中身がまだ分からない・新しいコピーが失敗した）は、それが
        // **最後の 1 枚**でも消えた。コピーの後に確かめるのは、置き換え先が在るかを見るため。
        let verdicts = await review.classify(presentAfterCopy: presentPaths.union(copiedDestinations))
        if !review.candidates.isEmpty {
            await removeReviewed(candidates: review.candidates, verdicts: verdicts, label: set.name,
                                 holdingFolder: set.folderName, baseFolder: setFolder,
                                 wholeFolder: nil, removal: removal,
                                 stillApplies: membersUnchanged(set, members: review.memberKeys, store: store))
        }

        await store.recordShareSyncCounts(setID: set.id,
                                          present: plan.present + copied,
                                          waiting: plan.waitingBackup.count)

        // コピーした分の解析データを足す（一覧はコピー前のものなので、ここで補う）。
        if copied > 0 {
            let late = review.analysisInputs(present: presentPaths.union(copiedDestinations), verdicts: verdicts)
            await updateAnalysisData(set: set, setFolder: setFolder, items: items,
                                     presentPathsLower: late.present, sourceByRefKey: late.sources,
                                     copier: copier, token: token,
                                     remoteAnalysisFiles: remote.analysisFiles(inSetFolder: setFolder)
                                        + uploadedShardNames.map {
                                            DropboxShareCopier.ListedFile(
                                                pathLower: "", name: $0.name, rev: nil,
                                                contentHash: $0.hash, isFolder: false)
                                        })
        }
    }

    // MARK: - 段

    /// 準備の段の結果。
    struct PreparedSet {
        let items: [ShareItemLite]
        let setFolder: String
        let remoteFiles: [SharePlanning.RemoteFile]
    }

    /// メンバーを読み、セットのフォルダを用意する。この回は何もしないなら nil。
    private func prepareSet(_ set: ShareSetLite, shareRoot: String, store: BackupStore,
                            copier: DropboxShareCopier, token: String,
                            remote: RemoteShareIndex) async -> PreparedSet? {
        // ⚠️ 読めなかったら**このセットは見送る**（ADR-277）。空として進むと「メンバー 0」と読んで
        // フォルダの中身を全部消す（差分方式では「望ましい集合が空」も正しい答えなので）。
        guard let items = await store.readShareItems(setID: set.id) else {
            Diagnostics.mark("share sync: '\(set.name)' のメンバーが読めない — この回は見送る")
            return nil
        }
        guard let setFolder = SharePlanning.setFolderPath(
                shareRoot: shareRoot, folderName: set.folderName,
                deviceFolder: nil /* ADR-175: shareRoot は端末フォルダ込み */) else {
            BackupLogger.error("Share sync: invalid folder name — skipping set")
            return nil
        }
        // ⚠️ **メンバーが 0 でも掃除は走らせる**（不変条件テストが捕まえた）。
        // 「空のセットだから何もしない」と早期に戻ると、フォルダに残った自分のコピーが
        // 誰にも掃除されない孤児になる——差分方式では「望ましい集合が空」も立派な答えで、
        // 実在との差分を取れば全部消える。
        // 何もする必要が無いのは「メンバーも実在も無い」ときだけ。
        let folderExists = remote.hasFolder(setFolder)
        guard !items.isEmpty || folderExists else {
            await store.recordShareSyncCounts(setID: set.id, present: 0, waiting: 0)
            return nil
        }

        // セットのフォルダが無ければ作る（初回か外部削除）。実在はルートの再帰一覧から分かる
        // ＝セットごとの往復は無い（ADR-183）。
        if !folderExists {
            switch await copier.createFolder(path: setFolder, token: token) {
            case .created:
                break
            case .alreadyExisted:
                // ⚠️ 一覧には無かったのに在った＝**一覧がこのフォルダを取りこぼしている**
                // （一覧の後に作られた・一覧が古い）。実在が分からないので、このセットは見送る
                // ——進めると、在るファイルを全部「未コピー」と読む（ルートと同じ形・ADR-277）。
                Diagnostics.mark("share sync: '\(set.name)' のフォルダが一覧に無いのに在った — この回は見送る")
                return nil
            case .failed:
                lastError = .folderPrepareFailed
                BackupLogger.error("Share sync: create_folder failed — \(setFolder)")
                return nil
            }
        }
        let remoteFiles = remote.photoFiles(inSetFolder: setFolder)
            .map { SharePlanning.RemoteFile(pathLower: $0.pathLower, contentHash: $0.contentHash) }
        return PreparedSet(items: items, setFolder: setFolder, remoteFiles: remoteFiles)
    }

    /// 同期一覧に載っていないクラウド写真の中身を、**少しだけ** Dropbox に訊いて足す。
    private func resolveCloudHashes(items: [ShareItemLite], known cloudHashes: [String: String]?,
                                    copier: DropboxShareCopier, token: String) async -> [String: String]? {
        // 同期一覧に載っていないクラウド写真の中身は、**少しだけ** Dropbox に訊く（レビュー指摘）。
        // 載っていないまま待つと、取り込み元のフォルダを変えた写真などは永久にコピーされない。
        // 一覧そのものが空（起動直後で表がまだ無い）なら訊かない——全員が欠けて見えるので。
        // ⚠️ 訊いた答えは覚える（毎回同じ 50 枚を訊かない・51 枚目以降が永久に訊かれないことも無くす）。
        // 無かった原本はこのプロセスのあいだ訊き直さない（無いものを繰り返し探さない）。
        guard var known = cloudHashes, !known.isEmpty else { return cloudHashes }
        known.merge(learnedCloudHashes) { current, _ in current }
        let missing = items.map(\.refKey).filter { $0.hasPrefix("C-") }
            .map { String($0.dropFirst(2)) }
            .filter { known[$0.lowercased()] == nil && !missingCloudOriginals.contains($0.lowercased()) }
        // 回ごとに始める位置をずらす（訊けなかった原本が毎回同じ 50 枠を埋めないように）。
        let ordered = missing.sorted()
        let begin = ordered.isEmpty ? 0 : (reviewRotation % ordered.count + ordered.count) % ordered.count
        // ⚠️ 上限は**反映 1 回ぶん**（セットごとに 50 だと、セットが多いと短い窓を食い潰す・独立レビュー 4 回目）。
        // セットごとの取り分（先頭のセットが毎回 50 を使い切って、後ろのセットが永久に訊かれない、を無くす）。
        // 残りの枠を、まだ回っていないセットで割る（使わないセットの取り分を無駄にしない）。
        let share = max(1, cloudLookupsLeftThisSync / max(1, cloudLookupSetCount))
        cloudLookupSetCount = max(1, cloudLookupSetCount - 1)
        for path in (ordered[begin...] + ordered[..<begin]).prefix(max(0, min(share, cloudLookupsLeftThisSync))) {
            guard !shouldStopAtBreak else { break }
            cloudLookupsLeftThisSync -= 1
            switch await copier.lookup(path: path, token: token) {
            case .file(let hash?):
                known[path.lowercased()] = hash
                learnedCloudHashes[path.lowercased()] = hash
            case .notFound:
                missingCloudOriginals.insert(path.lowercased())
            case .file(nil), .failed:
                break
            }
        }
        return known
    }

    /// 計画の 1 行と、詰まっている状態の印（変わったときだけ出す・解消したら消す）。
    private func reportPlan(_ plan: SharePlanning.Plan, set: ShareSetLite, items: [ShareItemLite]) {
        BackupLogger.info("Share sync: '\(set.folderName)' items=\(items.count) "
            + "copy=\(plan.copies.count) present=\(plan.present) "
            + "delete=\(plan.deletions.count) waitingBackup=\(plan.waitingBackup.count) "
            + "waitingCloud=\(plan.waitingCloudHash.count)")
        if plan.waitingCloudHash.isEmpty { clearMark(key: "waitingCloud-\(set.id)") }
        if !plan.noSourceResolved { clearMark(key: "noSource-\(set.id)") }
        if !plan.waitingCloudHash.isEmpty {
            markOnChange(key: "waitingCloud-\(set.id)", "share: '\(set.name)' 中身が分からないクラウド写真 \(plan.waitingCloudHash.count) 枚は"
                             + "この回コピーしない（原本が同期の外か、消えている）")
        }
        if plan.noSourceResolved {
            // ⚠️ 黙って何もしない状態を作らない（実機で「詰まっているのにログが無い」を何度も踏んだ）。
            markOnChange(key: "noSource-\(set.id)", "share: '\(set.name)' 元が 1 件も解決できない（メンバー \(items.count) 件）"
                             + " — メンバーのコピーは消す前の確認で残す")
        }
    }

    /// コピー。1 回の上限を超える分は次回に回す（レート制限を誘発しない）。
    /// 戻り値は (コピーできた数, 実際にコピーできた宛先（小文字）)。
    private func copyPlanned(_ plan: SharePlanning.Plan, set: ShareSetLite,
                             copier: DropboxShareCopier, token: String) async -> (Int, Set<String>) {
        var copied = 0
        /// 実際にコピーできた宛先（小文字）。⚠️ **「投げた分」ではなく「成功した分」**を持つ——
        /// 解析データはここに在る写真のぶんだけ作るので、失敗した宛先を混ぜると
        /// 受信側に突合できないエントリを送ることになる（次の反映で上げ直しにもなる）。
        var copiedDestinations = Set<String>()
        let budget = min(plan.copies.count, Self.maxCopiesPerRun)
        if plan.copies.count > budget {
            BackupLogger.info("Share sync: '\(set.folderName)' copying \(budget) of \(plan.copies.count) this run")
        }
        for chunk in stride(from: 0, to: budget, by: Self.copyChunkSize).map({
            Array(plan.copies[$0..<min($0 + Self.copyChunkSize, budget)])
        }) {
            guard !shouldStopAtBreak else { break }
            let entries = chunk.map { (from: $0.fromPath, to: $0.toPath) }
            let result = await copier.copyBatch(entries: entries, token: token)
            for (index, copy) in chunk.enumerated() {
                guard let entry = result?.entries[index] ?? nil else { continue }
                copied += 1
                // 実パスは Dropbox の応答から取る（こちらの組んだ宛先と同じはずだが、
                // 正規化の差を取り込まないよう応答を正とする）。
                copiedDestinations.insert(entry.pathLower.isEmpty
                                          ? copy.toPath.lowercased() : entry.pathLower)
            }
        }
        if copied > 0 {
            BackupLogger.info("Share: '\(set.folderName)' copied \(copied)/\(plan.copies.count)")
        }
        return (copied, copiedDestinations)
    }

    /// 消す直前に、セットとメンバーが反映の始めと同じかを確かめる関数。
    ///
    /// ⚠️ **消す直前に、セットとメンバーを読み直す**（独立レビュー 2 回目）。この関数は数分かかり、
    /// その間に利用者がセットを消して同じ名前で作り直したり、写真を入れ直したりできる。
    /// 古いメンバーで分類したまま消すと、入れ直した写真のコピーを「持ち主なし」と読む。
    /// 変わっていたら、この回は消さない（次の回が新しいメンバーで決め直す）。
    private func membersUnchanged(_ set: ShareSetLite, members memberKeys: [String],
                                  store: BackupStore) -> @MainActor () async -> Bool {
        let setID = set.id
        let folderName = set.folderName
        let label = set.name
        let memberSet = Set(memberKeys)
        return {
            guard let sets = await store.readShareSets(),
                  let fresh = await store.readShareItems(setID: setID) else {
                Diagnostics.mark("share: '\(label)' 消す直前にセットかメンバーが読めない — この回は消さない")
                return false
            }
            guard sets.contains(where: { $0.id == setID && $0.folderName == folderName }),
                  Set(fresh.map(\.refKey)) == memberSet else {
                Diagnostics.mark("share: '\(label)' 反映の途中でセットかメンバーが変わった — この回は消さない")
                return false
            }
            return true
        }
    }
}

/// 1 セットぶんの「消す前の確認」と「解析データに載せる写真」の材料（ADR-278）。
///
/// 消す候補の分類（`classify`）はコピーの前と後の 2 回呼ぶ（前は解析データ用、後は掃除用）。
/// 材料は同じなので、ここに 1 回だけ組んで持つ。
struct ShareSetReview {
    let plan: SharePlanning.Plan
    /// 消す候補（計画の削除のうち実在するもの）。
    let candidates: [SharePlanning.RemoteFile]
    let memberKeys: [String]
    private let hashByPath: [String: String]
    private let presentHashes: Set<String>
    private let sourceFileNames: [String: String]
    private let destinations: [String: String]
    private let rotation: Int

    init(plan: SharePlanning.Plan, items: [ShareItemLite], remoteFiles: [SharePlanning.RemoteFile],
         presentPaths: Set<String>, rotation: Int) {
        self.plan = plan
        // 消す候補のうち**メンバーのコピーとして残すもの**（ADR-278）。家族からは見えているので、
        // 解析データにも載せる（載せないと、記録が消えた写真のタグ・顔が家族の側で消える）。
        let deletionSet = Set(plan.deletions)
        candidates = remoteFiles.filter { deletionSet.contains($0.pathLower) }
        let hashByPath = Dictionary(remoteFiles.map { ($0.pathLower, $0.contentHash ?? "") },
                                    uniquingKeysWith: { first, _ in first })
        self.hashByPath = hashByPath
        presentHashes = Set(presentPaths.compactMap { hashByPath[$0] }.filter { !$0.isEmpty })
        // 元のファイル名が分かるメンバー（解決できた写真・クラウド写真）。照合をファイル名の幹で絞る。
        var sourceFileNames: [String: String] = [:]
        for item in items {
            if let source = plan.sourceByRefKey[item.refKey] {
                sourceFileNames[item.refKey] = (source.fromPath as NSString).lastPathComponent
            } else if item.refKey.hasPrefix("C-") {
                sourceFileNames[item.refKey] = (String(item.refKey.dropFirst(2)) as NSString).lastPathComponent
            }
        }
        self.sourceFileNames = sourceFileNames
        memberKeys = items.map(\.refKey)
        destinations = plan.sourceByRefKey.mapValues(\.destinationLower)
        self.rotation = rotation
    }

    /// 中身の分からないファイルは nil（空文字を鍵にした解析データを作らない・独立レビュー 2 回目）。
    func knownHash(_ path: String) -> String? { hashByPath[path].flatMap { $0.isEmpty ? nil : $0 } }

    /// 消す候補を分類する。
    func classify(presentAfterCopy: Set<String>) async -> [String: ShareDeletionReview.Verdict] {
        guard !candidates.isEmpty else { return [:] }
        let candidates = candidates, memberKeys = memberKeys, sourceFileNames = sourceFileNames
        let destinations = destinations, presentHashes = presentHashes, rotation = rotation
        // ⚠️ メインから外す（SHA-256 をメンバー数ぶん回し得る・レビュー指摘）。
        return await Task.detached(priority: .utility) {
            ShareDeletionReview.classify(
                candidates: candidates, members: memberKeys, sourceFileNames: sourceFileNames,
                destinationByRefKey: destinations,
                presentAfterCopy: presentAfterCopy, presentHashes: presentHashes,
                startOffset: rotation * 97)
        }.value
    }

    /// 解析データに載せる写真（置かれている宛先と、refKey → 元）。メンバーのコピーとして残すものも足す。
    func analysisInputs(present: Set<String>, verdicts: [String: ShareDeletionReview.Verdict])
        -> (present: Set<String>, sources: [String: SharePlanning.SourceRef]) {
        var present = present
        var sources = plan.sourceByRefKey
        for (path, verdict) in verdicts.sorted(by: { $0.key < $1.key }) {
            guard case .keptForMember(let refKey) = verdict else { continue }
            if let current = sources[refKey], present.contains(current.destinationLower) { continue }
            sources[refKey] = SharePlanning.SourceRef(fromPath: path, contentHash: knownHash(path),
                                                      destinationLower: path)
            present.insert(path)
        }
        return (present, sources)
    }
}
