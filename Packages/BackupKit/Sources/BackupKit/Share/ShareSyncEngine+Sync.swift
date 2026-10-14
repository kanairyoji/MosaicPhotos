import DropboxCore
import Foundation
import MosaicSupport

// MARK: - 反映（差分・ADR-209）
//
// `ShareSyncEngine` の**反映**（Dropbox へ実際に書く側）をここに分ける。
// 本体（`ShareSyncEngine.swift`）は状態とセット操作（UI から呼ぶ CRUD）に専念する。
//
// ## 骨組み
// ```
// 共有ルートを再帰で 1 回一覧
//   ├ フォルダの差分: 望ましいセットフォルダ − 実在フォルダ → 余りを消す
//   └ セットごとに
//       ├ 写真の差分:   望ましい（中身で決まる名前）− 実在 → コピー / 余りを消す
//       └ 解析データ:   シャードの content_hash 比較 → 上げる / 消す
// ```
// **記録を見て食い違いを直す**のではなく、**望ましい姿を作って差分を取る**。
// だから採用・自己修復・ドリフト検知・墓標・残骸掃除がどれも要らない。

extension ShareSyncEngine {

    /// 全セットを反映する（コピー・掃除・解析データ更新）。
    /// バックアップ完走後・手動「今すぐ反映」・夜間枠から呼ばれる。
    public func syncNow() async {
        // 「提供する」が OFF なら反映しない（受信・バックアップとは独立・ADR-112 追記）。
        guard ShareSettingsKeys.isProvideEnabled(defaults) else { return }
        // ⚠️ 旗は**最初の await より前**に立てる。`@MainActor` でも await で実行が移るため、
        // トークン取得を挟んでからだと 2 本が同時にガードを通過する（TOCTOU・レビュー指摘）。
        // 走行中に来た要求は捨てずに 1 回だけ再走させる（捨てると「共有したのに反映されない」）。
        // ⚠️ **走行中でも呼び手を待たせる**。以前はここで即 return していたので、
        // 「今すぐ反映」を押しても、夜間の反映が走っていると**何もせずに戻って**いた
        // （呼び手は終わったと思う）。予約だけして返すのは嘘で、テストも同じ形で騙された
        // ——`deleteSet` の直後に `syncNow()` を呼んでも走らず、掃除されないと読み違えた。
        // 走行中の回の末尾で `needsAnotherPass` が消化されるので、それを待てばよい。
        guard !isSyncing else {
            needsAnotherPass = true
            await syncTask?.value
            return
        }
        isSyncing = true
        let task = Task { await performSync() }
        syncTask = task
        await task.value
    }

    /// バックアップが終わったときに呼ぶ。待っていた共有写真が無ければ反映しない（`ShareAfterBackupGate`）。
    public func syncAfterBackup() async {
        guard ShareSettingsKeys.isProvideEnabled(defaults) else { return }
        let waiting = await storeProvider().shareWaitingBackupCounts()
        guard ShareAfterBackupGate.shouldSync(waitingBackup: waiting) else {
            // ⚠️ 効いた回数が見えるログ（ADR-250）。無いと「一度も効かない」に気づけない。
            Diagnostics.mark("share sync: バックアップ後の反映を見送る（待っている共有写真が無い・"
                             + "\(waiting?.count ?? 0) セット）")
            return
        }
        await syncNow()
    }

    private func performSync() async {
        defer { isSyncing = false }
        // 停止を跨いだ回を見分けるために、始めた時点の中断の世代を控える（diagnostics-109）。
        let suspensionEpoch = ProcessSuspension.epoch

        guard let token = try? await tokenProvider.freshAccessToken() else {
            lastError = .notConnected
            BackupLogger.info("Share sync: skipped (no token)")
            return
        }
        lastError = nil

        let store = await storeProvider()
        // ⚠️⚠️ **台帳がこの起動だけインメモリに落ちていたら、何も書かない**（ADR-278）。
        // 一時的な失敗（容量不足・ファイル保護）で開けなかった台帳は、セットも記録も**空として
        // 読めてしまう**——読めなかった（ADR-277）とは違い、読む側からは区別がつかない。
        if store.isTemporaryFallback {
            lastError = .ledgerUnavailable
            Diagnostics.mark("share sync: 台帳が一時的にインメモリで開いている — この起動では反映しない")
            return
        }
        let copier = makeCopier()
        let shareRoot = ShareSettingsKeys.currentShareRoot(defaults)
        let sets = await store.allShareSets()

        // ⚠️ 共有ルートは**無いときだけ**作る。毎回投げると 1 往復を捨て続けることになる
        //（409＝既存で無害だが、落ち着いた反映は 1 往復も書かないのが正しい）。
        let listing: [DropboxShareCopier.ListedFile]
        if let fetched = await copier.listFolder(path: shareRoot, token: token, recursive: true) {
            listing = fetched
        } else if sets.isEmpty {
            // ⚠️ **セットが 1 つも無いなら、共有ルートが無いのが正常**（作りに行かない）。
            // ここをエラーにすると、提供を ON にしただけでまだ何も共有していない利用者に
            // **毎回の反映でエラーが出る**（画面に赤字が出たまま消えない）。
            lastSyncAt = Date()
            return
        } else {
            // ⚠️⚠️ **「空」と言えるのは、いま作ったときだけ**（ADR-277・diagnostics-108）。
            // 一覧が取れない理由は「ルートがまだ無い（初回）」と「通信がこけた」の 2 つあり、
            // 作成の応答で見分ける。以前は 409（既にある）も成功として**空**で進んだので、
            // 停止からの復帰直後に一覧だけ失敗した回、置き済みの 21,191 枚を全部
            // 「未コピー」と読んで 500 件のコピーを投げ、「共有済み」を 0 に書き換えていた。
            // 計画（`SharePlanning.plan`）の「一覧が無ければ何も決めない」が、ここで
            // 空の一覧に化けて**効かなくなっていた**。
            switch await copier.createFolder(path: shareRoot, token: token) {
            case .created:
                listing = []   // ルートがまだ無かった（初回）。いま作ったので中身は空。
            case .alreadyExisted:
                // ルートは在るのに一覧が取れなかった＝実在が分からない。この回は何も決めない。
                lastError = .folderCheckFailed
                Diagnostics.mark("share sync: 共有ルートの一覧が取れない — この回は見送る（\(sets.count) セット）"
                                 + Self.suspensionNote(since: suspensionEpoch))
                return
            case .failed:
                lastError = .folderCheckFailed
                // ⚠️ **停止を跨いだ回は error にしない**（diagnostics-109・ADR-256）。
                // 期限切れの窓は反映の終わりを待たないので、投げた通信ごと 30 分止まり、
                // 次の窓で起こされた瞬間に一覧も作成も落ちる。何も決めずに抜けるのは
                // 正しく（ADR-277）、次の回で直る——これを error に残すと本物の障害が埋もれる。
                if ProcessSuspension.didSuspend(since: suspensionEpoch) {
                    Diagnostics.mark("share sync: 共有ルートの一覧も作成も落ちた — この回は見送る"
                                     + Self.suspensionNote(since: suspensionEpoch))
                } else {
                    BackupLogger.error("Share sync: list_folder(recursive) failed — \(shareRoot)")
                }
                return
            }
        }
        let remote = RemoteShareIndex(listing: listing)
        let account = accountFingerprint()
        cloudLookupsLeftThisSync = Self.maxCloudHashLookupsPerSync
        cloudLookupSetCount = sets.count
        if Date().timeIntervalSince(cloudLookupCacheStartedAt) > 24 * 3_600 || account != cloudLookupCacheAccount {
            learnedCloudHashes.removeAll()
            missingCloudOriginals.removeAll()
            cloudLookupCacheStartedAt = Date()
            cloudLookupCacheAccount = account
        }
        // クラウド原本の中身（10 万行の射影）は**反映 1 回に 1 度だけ**引く。宛先名と、
        // 消す前の確認（中身が他に在るか）の両方に使う。
        let cloudHashes = await cloudSourceHashProvider?()
        // ⚠️ 設定は自由入力なので、配置と同じ正規化を通す（先頭の / の有無・末尾の Backup / Share・
        // 前後の空白で前方一致が外れ、他の端末の共有コピーを証拠に数えていた・独立レビュー 2 回目）。
        let rawRoot = defaults.string(forKey: BackupSettingsKeys.dropboxFolder)
            ?? BackupSettingsKeys.defaultDropboxFolder
        let removal = RemovalContext(layoutRoot: BackupLayout.deviceRoot(root: rawRoot, deviceFolder: ""),
                                     shareRoot: shareRoot,
                                     holdingRoot: ShareSettingsKeys.currentShareRemovedRoot(defaults),
                                     cloudHashes: cloudHashes, store: store,
                                     copier: copier, token: token)

        // ⚠️ メンバー数は**1 回だけ数えて使い回す**（ADR-119）。セットごとに数え直すと
        // 「メンバー総数 × セット数」行を 1 回の反映で射影することになる。
        let totals = await store.shareItemTotals()
        for set in sets {
            guard !Task.isCancelled else {
                needsAnotherPass = true
                break
            }
            await sync(set: set, shareRoot: shareRoot, store: store,
                       copier: copier, token: token, remote: remote, removal: removal)
            await refresh(totals: totals)   // 進捗（共有済み N/M）を UI へ（変化なしなら無通知）
        }
        // ⚠️ **フォルダの掃除は最後**（紛らわしい名前のテストが捕まえた）。
        // 先にやると、**コピー元が掃除対象のフォルダに在る**場合に元を消してからコピーする
        // ことになり、コピーが永久に失敗する（クラウド写真は共有ルートの中にも在り得る）。
        // 掃除は「どのセットも持たないフォルダを消す」だけなので、後回しにしても
        // 判断は変わらない——変わるのは「元を取り終わってから消す」ことだけ。
        // 掃除にも、セットごとの反映で覚えたクラウド原本の中身を渡す（同じ判断に同じ材料・ADR-196）。
        let sweepRemoval = RemovalContext(
            layoutRoot: removal.layoutRoot, shareRoot: removal.shareRoot, holdingRoot: removal.holdingRoot,
            cloudHashes: removal.cloudHashes.map { $0.merging(learnedCloudHashes) { current, _ in current } },
            store: removal.store, copier: removal.copier, token: removal.token)
        await sweepRetiredFolders(remote: remote, removal: sweepRemoval)

        lastSyncAt = Date()
        await refresh()

        // 走行中に来た要求をここで 1 回だけ消化する（無限再帰にならないよう旗を先に落とす）。
        if needsAnotherPass {
            needsAnotherPass = false
            isSyncing = false
            await syncNow()
        }
    }

    /// 停止を跨いだ回なら、ログの末尾に添える一言（跨いでいなければ空）。
    /// ⚠️ 前の窓が残した反映は**次の窓の頭**に失敗を出すので、窓を取り違えないように書く。
    static func suspensionNote(since epoch: Int) -> String {
        ProcessSuspension.didSuspend(since: epoch) ? "（停止を跨いだ回＝停止の前に始めた反映）" : ""
    }

    private func sync(set: ShareSetLite, shareRoot: String, store: BackupStore,
                      copier: DropboxShareCopier, token: String, remote: RemoteShareIndex,
                      removal: RemovalContext) async {
        // ⚠️ 読めなかったら**このセットは見送る**（ADR-277）。空として進むと「メンバー 0」と読んで
        // フォルダの中身を全部消す（差分方式では「望ましい集合が空」も正しい答えなので）。
        guard let items = await store.readShareItems(setID: set.id) else {
            Diagnostics.mark("share sync: '\(set.name)' のメンバーが読めない — この回は見送る")
            return
        }
        guard let setFolder = SharePlanning.setFolderPath(
                shareRoot: shareRoot, folderName: set.folderName,
                deviceFolder: nil /* ADR-175: shareRoot は端末フォルダ込み */) else {
            BackupLogger.error("Share sync: invalid folder name — skipping set")
            return
        }
        // ⚠️ **メンバーが 0 でも掃除は走らせる**（不変条件テストが捕まえた）。
        // 「空のセットだから何もしない」と早期に戻ると、フォルダに残った自分のコピーが
        // 誰にも掃除されない孤児になる——差分方式では「望ましい集合が空」も立派な答えで、
        // 実在との差分を取れば全部消える。
        // 何もする必要が無いのは「メンバーも実在も無い」ときだけ。
        let folderExists = remote.hasFolder(setFolder)
        guard !items.isEmpty || folderExists else {
            await store.recordShareSyncCounts(setID: set.id, present: 0, waiting: 0)
            return
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
                return
            case .failed:
                lastError = .folderPrepareFailed
                BackupLogger.error("Share sync: create_folder failed — \(setFolder)")
                return
            }
        }
        let remoteFiles = remote.photoFiles(inSetFolder: setFolder)
            .map { SharePlanning.RemoteFile(pathLower: $0.pathLower, contentHash: $0.contentHash) }

        // 計画（純ロジック）: 望ましい集合と実在の差分。
        let localIDs = items.filter { $0.refKey.hasPrefix("L-") }
            .map { String($0.refKey.dropFirst(2)) }
        guard let backupRefs = await store.readBackupRefs(forLocalIdentifiers: localIDs) else {
            Diagnostics.mark("share sync: '\(set.name)' のバックアップ記録が読めない — この回は見送る")
            return
        }
        // 同期一覧に載っていないクラウド写真の中身は、**少しだけ** Dropbox に訊く（レビュー指摘）。
        // 載っていないまま待つと、取り込み元のフォルダを変えた写真などは永久にコピーされない。
        // 一覧そのものが空（起動直後で表がまだ無い）なら訊かない——全員が欠けて見えるので。
        // ⚠️ 訊いた答えは覚える（毎回同じ 50 枚を訊かない・51 枚目以降が永久に訊かれないことも無くす）。
        // 無かった原本はこのプロセスのあいだ訊き直さない（無いものを繰り返し探さない）。
        var cloudHashes = removal.cloudHashes
        if var known = cloudHashes, !known.isEmpty {
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
                guard !Task.isCancelled else { break }
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
            cloudHashes = known
        }
        // 覚えた中身は、消す前の確認の証拠にも使う（原本が在るのに「どこにも無い」と読まない）。
        let removal = RemovalContext(layoutRoot: removal.layoutRoot, shareRoot: removal.shareRoot,
                                     holdingRoot: removal.holdingRoot, cloudHashes: cloudHashes,
                                     store: removal.store, copier: removal.copier, token: removal.token)
        let plan = SharePlanning.plan(items: items, backupByLocalID: backupRefs,
                                      cloudHashByPath: cloudHashes,
                                      setFolder: setFolder, remoteFiles: remoteFiles)

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

        // 解析データは**コピーの前に**、いま置かれている分で揃える（ADR-183）。
        // コピーは数分かかるので、後回しだと「反映を押しても解析データが何分も更新されない」。
        let presentPaths = Set(remoteFiles.map(\.pathLower))
            .subtracting(plan.deletions)
        // 消す候補のうち**メンバーのコピーとして残すもの**（ADR-278）。家族からは見えているので、
        // 解析データにも載せる（載せないと、記録が消えた写真のタグ・顔が家族の側で消える）。
        let deletionSet = Set(plan.deletions)
        let candidates = remoteFiles.filter { deletionSet.contains($0.pathLower) }
        let hashByPath = Dictionary(remoteFiles.map { ($0.pathLower, $0.contentHash ?? "") },
                                    uniquingKeysWith: { first, _ in first })
        /// 中身の分からないファイルは nil（空文字を鍵にした解析データを作らない・独立レビュー 2 回目）。
        func knownHash(_ path: String) -> String? { hashByPath[path].flatMap { $0.isEmpty ? nil : $0 } }
        let presentHashes = Set(presentPaths.compactMap { hashByPath[$0] }.filter { !$0.isEmpty })
        // 元のファイル名が分かるメンバー（解決できた写真・クラウド写真）。照合をファイル名の幹で絞る。
        var sourceFileNames: [String: String] = [:]
        for item in items {
            if let source = plan.sourceByRefKey[item.refKey] {
                sourceFileNames[item.refKey] = (source.fromPath as NSString).lastPathComponent
            } else if item.refKey.hasPrefix("C-") {
                sourceFileNames[item.refKey] = (String(item.refKey.dropFirst(2)) as NSString).lastPathComponent
            }
        }
        let memberKeys = items.map(\.refKey)
        let destinations = plan.sourceByRefKey.mapValues(\.destinationLower)
        reviewRotation &+= 1
        let rotation = reviewRotation
        func review(presentAfterCopy: Set<String>) async -> [String: ShareDeletionReview.Verdict] {
            guard !candidates.isEmpty else { return [:] }
            // ⚠️ メインから外す（SHA-256 をメンバー数ぶん回し得る・レビュー指摘）。
            return await Task.detached(priority: .utility) {
                ShareDeletionReview.classify(
                    candidates: candidates, members: memberKeys, sourceFileNames: sourceFileNames,
                    destinationByRefKey: destinations,
                    presentAfterCopy: presentAfterCopy, presentHashes: presentHashes,
                    startOffset: rotation * 97)
            }.value
        }
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
        let early = analysisInputs(present: presentPaths, verdicts: await review(presentAfterCopy: presentPaths))
        await updateAnalysisData(set: set, setFolder: setFolder, items: items,
                                 presentPathsLower: early.present, sourceByRefKey: early.sources,
                                 copier: copier, token: token,
                                 remoteAnalysisFiles: remote.analysisFiles(inSetFolder: setFolder))

        // コピー。1 回の上限を超える分は次回に回す（レート制限を誘発しない）。
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
            guard !Task.isCancelled else { needsAnotherPass = true; break }
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

        // 掃除。⚠️ **消す前に、消す理由と中身の行き先を確かめる**（ADR-278）。
        // 以前は「望ましくない」＝引き算の結果をそのまま消していた（ADR-209）。材料が欠けた回
        // （記録が照合で消えた・中身がまだ分からない・新しいコピーが失敗した）は、それが
        // **最後の 1 枚**でも消えた。コピーの後に確かめるのは、置き換え先が在るかを見るため。
        let verdicts = await review(presentAfterCopy: presentPaths.union(copiedDestinations))
        // ⚠️ **消す直前に、セットとメンバーを読み直す**（独立レビュー 2 回目）。この関数は数分かかり、
        // その間に利用者がセットを消して同じ名前で作り直したり、写真を入れ直したりできる。
        // 古いメンバーで分類したまま消すと、入れ直した写真のコピーを「持ち主なし」と読む。
        // 変わっていたら、この回は消さない（次の回が新しいメンバーで決め直す）。
        let setID = set.id
        let folderName = set.folderName
        let label = set.name
        let memberSet = Set(memberKeys)
        let unchanged: @MainActor () async -> Bool = {
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
        if !candidates.isEmpty {
            await removeReviewed(candidates: candidates, verdicts: verdicts, label: set.name,
                                 holdingFolder: set.folderName, baseFolder: setFolder,
                                 wholeFolder: nil, removal: removal, stillApplies: unchanged)
        }

        await store.recordShareSyncCounts(setID: set.id,
                                          present: plan.present + copied,
                                          waiting: plan.waitingBackup.count)

        // コピーした分の解析データを足す（一覧はコピー前のものなので、ここで補う）。
        if copied > 0 {
            let late = analysisInputs(present: presentPaths.union(copiedDestinations), verdicts: verdicts)
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

    /// 解析データを**シャード単位**で同期する（ADR-183）。
    ///
    /// 状態は持たない: 「上げるべきか」は共有ルートの再帰一覧にある各シャードの `content_hash` と、
    /// 手元で組んだシャードの `content_hash`（同じ計算・`DropboxContentHash`）の比較だけで決まる。
    /// 消された解析データの復元（ADR-166）は「遠隔に無い → 上げる」に自然に含まれる。
    ///
    /// ⚠️ 解析データのキーは**写真の content_hash**（受信側が自分の同期一覧と突合するため）。
    /// 共有フォルダに実際に置かれている写真のぶんだけ載せる——まだコピーしていない写真の
    /// 解析結果を載せても、受信側には突合する相手が居ない。
    private func updateAnalysisData(set: ShareSetLite, setFolder: String, items: [ShareItemLite],
                                    presentPathsLower: Set<String>,
                                    sourceByRefKey: [String: SharePlanning.SourceRef],
                                    copier: DropboxShareCopier, token: String,
                                    remoteAnalysisFiles: [DropboxShareCopier.ListedFile]) async {
        uploadedShardNames.removeAll()
        guard let analysisSource else { return }

        // 共有フォルダに置かれている写真（refKey → その写真の content_hash）。
        var sharedRefKeys: [String] = []
        var hashByRefKey: [String: String] = [:]
        for item in items {
            guard let source = sourceByRefKey[item.refKey],
                  let hash = source.contentHash,
                  presentPathsLower.contains(source.destinationLower) else { continue }
            sharedRefKeys.append(item.refKey)
            hashByRefKey[item.refKey] = hash.lowercased()
        }
        guard !sharedRefKeys.isEmpty else { return }

        let payload = await analysisSource.analysisEntries(forRefKeys: sharedRefKeys)
        var entriesByHash: [String: ShareAnalysisData.Entry] = [:]
        for refKey in sharedRefKeys {
            guard let hash = hashByRefKey[refKey], let entry = payload.entries[refKey] else { continue }
            entriesByHash[hash] = entry
        }
        guard !entriesByHash.isEmpty else { return }

        // シャードのエンコードと content_hash は数 MB 規模になり得るのでオフメインで。
        let versions = payload.versions
        let local: [String: (data: Data, hash: String)] = await Task.detached(priority: .utility) {
            var out: [String: (data: Data, hash: String)] = [:]
            for (shard, file) in ShareAnalysisData.shards(versions: versions, entries: entriesByHash) {
                guard let data = ShareAnalysisData.encode(file) else { continue }
                out[shard] = (data, DropboxContentHash.hash(of: data))
            }
            return out
        }.value

        let plan = ShareAnalysisPlanning.plan(local: local.mapValues(\.hash),
                                              remote: remoteAnalysisFiles.map {
                                                  ShareAnalysisPlanning.RemoteFile(name: $0.name, contentHash: $0.contentHash)
                                              })
        guard !plan.upload.isEmpty || !plan.delete.isEmpty else { return }

        let analysisFolder = "\(setFolder)/\(ShareAnalysisData.subfolderName)"
        if !plan.upload.isEmpty {
            guard await copier.createFolder(path: analysisFolder, token: token).exists else { return }
        }
        var uploaded = 0
        for shard in plan.upload.sorted() {
            guard let entry = local[shard] else { continue }
            if await copier.uploadFile(data: entry.data,
                                       to: ShareAnalysisData.shardPath(setFolderPath: setFolder, shard: shard),
                                       token: token) {
                uploaded += 1
                uploadedShardNames.append((name: ShareAnalysisData.shardFileName(shard), hash: entry.hash))
            }
        }
        if !plan.delete.isEmpty {
            _ = await copier.deleteBatch(paths: plan.delete.map { "\(analysisFolder)/\($0)" }, token: token)
        }
        if uploaded > 0 || !plan.delete.isEmpty {
            let line = "Share: '\(set.folderName)' analysis shards +\(uploaded) -\(plan.delete.count) "
                + "(\(entriesByHash.count) entries in \(local.count) shards)"
            BackupLogger.info(line)
            Diagnostics.mark(line)   // Release でも実機ログに残す（検証の目印）
        }
    }
}

/// 共有ルートの再帰一覧を、フォルダ構成とセットごとの実在に切り出す（ADR-183）。
struct RemoteShareIndex {
    private let folders: Set<String>
    private let files: [DropboxShareCopier.ListedFile]

    init(listing: [DropboxShareCopier.ListedFile]) {
        folders = Set(listing.filter(\.isFolder).map(\.pathLower))
        files = listing.filter { !$0.isFolder }
    }

    func hasFolder(_ path: String) -> Bool { folders.contains(path.lowercased()) }

    /// 共有ルートの**直下**にあるフォルダ（セットフォルダの候補）。
    func directSubfolders(of root: String) -> [String] {
        let prefix = root.lowercased() + "/"
        return folders.filter { folder in
            guard folder.hasPrefix(prefix) else { return false }
            return !folder.dropFirst(prefix.count).contains("/")
        }
    }

    /// セットフォルダ**直下**の写真（解析データのフォルダ配下は含めない）。
    func photoFiles(inSetFolder setFolder: String) -> [DropboxShareCopier.ListedFile] {
        let prefix = setFolder.lowercased() + "/"
        return files.filter { file in
            guard file.pathLower.hasPrefix(prefix) else { return false }
            return !file.pathLower.dropFirst(prefix.count).contains("/")
        }
    }

    /// フォルダの下の**すべての**ファイル（深い階層も含む・解析データのフォルダは除く）。
    /// フォルダごと消す前に、中身を 1 つ残らず確かめるため（ADR-278）。
    func filesOutsideAnalysis(under folder: String) -> [DropboxShareCopier.ListedFile] {
        let prefix = folder.lowercased() + "/"
        let analysis = prefix + ShareAnalysisData.subfolderName + "/"
        return files.filter { $0.pathLower.hasPrefix(prefix) && !$0.pathLower.hasPrefix(analysis) }
    }

    /// セットの解析データファイル（シャード・旧形式）。
    func analysisFiles(inSetFolder setFolder: String) -> [DropboxShareCopier.ListedFile] {
        let prefix = setFolder.lowercased() + "/" + ShareAnalysisData.subfolderName + "/"
        return files.filter { $0.pathLower.hasPrefix(prefix) && ShareAnalysisData.isAnalysisFileName($0.name) }
    }
}

/// 解析データのシャードの差分計画（純ロジック・テスト対象）。
public enum ShareAnalysisPlanning {
    public struct RemoteFile: Sendable, Equatable {
        public let name: String
        public let contentHash: String?
        public init(name: String, contentHash: String?) { self.name = name; self.contentHash = contentHash }
    }
    public struct Plan: Equatable {
        /// 上げるシャード名。
        public var upload: [String] = []
        /// 消すファイル名（空になったシャード・旧形式）。
        public var delete: [String] = []
    }

    /// - Parameters:
    ///   - local: シャード名 → 手元で組んだファイルの content_hash。
    ///   - remote: `.mosaic-share` にある解析データファイル。
    public static func plan(local: [String: String], remote: [RemoteFile]) -> Plan {
        var plan = Plan()
        var remoteByName: [String: String?] = [:]
        for file in remote { remoteByName[file.name] = file.contentHash }
        for (shard, hash) in local {
            let name = ShareAnalysisData.shardFileName(shard)
            if remoteByName[name] != hash { plan.upload.append(shard) }
        }
        let localNames = Set(local.keys.map(ShareAnalysisData.shardFileName))
        for file in remote where !localNames.contains(file.name) {
            plan.delete.append(file.name)   // 空になったシャード、または旧形式
        }
        plan.upload.sort()
        plan.delete.sort()
        return plan
    }
}
