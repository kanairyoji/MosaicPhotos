import DropboxCore
import Foundation

// MARK: - 反映（コピー＋サイドカー）
//
// `ShareSyncEngine` の**反映**（Dropbox へ実際に書く側）をここに分ける。
// 本体（`ShareSyncEngine.swift`）は状態とセット操作（UI から呼ぶ CRUD）に専念する。
// ⚠️ 1 ファイル 855 行で「UI から呼ぶ操作」と「夜間に走る反映」が同居しており、
// どちらを読みたいときも全部を読む必要があった。振る舞いは変えていない（純粋な分割）。

extension ShareSyncEngine {


    /// 全セットを反映する（コピー・自己修復・サイドカー更新）。
    /// バックアップ完走後・手動「今すぐ反映」・夜間枠から呼ばれる。
    public func syncNow() async {
        // 「提供する」が OFF なら反映しない（受信・バックアップとは独立・ADR-112 追記）。
        guard ShareSettingsKeys.isProvideEnabled(defaults) else { return }
        // ⚠️ フラグは**最初の await より前**に立てる。`@MainActor` でも await で実行が移るため、
        // トークン取得を挟んでからだと 2 本が同時にガードを通過する（TOCTOU・レビュー指摘）。
        // 走行中に来た要求は捨てずに 1 回だけ再走させる（捨てると「共有したのに反映されない」）。
        guard !isSyncing else {
            needsAnotherPass = true
            return
        }
        // 削除系が走っている間は反映しない（消した先へコピーし直さないため）。
        guard !isMutating else {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        // 変更操作（削除・メンバー更新）が待てるよう、実体は**キャンセル可能な Task** で回す。
        // 直接 await すると呼び出し元の Task しか持てず、`waitForSyncToPause` が止められない。
        // ⚠️ ガードを**通った時だけ** `syncTask` を張り替える。畳まれた呼び出しで上書きすると、
        // キャンセルが「既に終わった Task」に飛んで実行中の反映が止まらない（自テストで検出）。
        let task = Task { await performSync() }
        syncTask = task
        await task.value
    }

    private func performSync() async {
        defer { isSyncing = false }

        guard let token = try? await tokenProvider.freshAccessToken() else {
            lastError = .notConnected
            BackupLogger.info("Share sync: skipped (no token)")
            return
        }
        lastError = nil

        let store = await storeProvider()
        let copier = makeCopier()
        let shareRoot = ShareSettingsKeys.currentShareRoot(defaults)

        await sweepDeletedFolders(copier: copier, token: token)

        for set in await store.allShareSets() {
            // 途中でユーザーが削除操作を始めたら、そこで止める（続きは次回の反映で拾う）。
            if isMutating || Task.isCancelled {
                needsAnotherPass = true
                break
            }
            // 端末フォルダ・種類接頭辞が入る前に作ったセットは、ここで**フォルダごと移動**して
            // 追いつかせる（作り直させるとクラウド上の写真をコピーし直すことになる）。
            let current = await migrateFolderIfNeeded(set: set, shareRoot: shareRoot,
                                                      store: store, copier: copier, token: token)
            await sync(set: current, shareRoot: shareRoot, store: store,
                       copier: copier, token: token)
            await refresh()   // セットごとに進捗（共有済み N/M）を UI へ反映（変化なしなら無通知）
        }
        lastSyncAt = Date()
        await refresh()

        // 走行中に来た要求をここで 1 回だけ消化する（無限再帰にならないようフラグを先に落とす）。
        if needsAnotherPass {
            needsAnotherPass = false
            isSyncing = false
            await syncNow()
        }
    }

    /// 既存セットのフォルダを**現在のレイアウトへ移行**する（Dropbox 側は改名＝サーバーサイド move）。
    ///
    /// 移行は 2 つある。どちらも作成時にしか適用されないので、既存セットは古いままになる:
    /// - **端末フォルダ**（`<root>/<端末名-短ID>/…`）: 複数人が同じ共有フォルダを使うため。
    /// - **種類接頭辞**（`Album-` / `Person-` / `People-`）: 何のアルバムか分かるようにするため。
    ///
    /// ⚠️ 端末フォルダ以前のセットが**そのままでは直らない**のが厄介な点だった。計画は
    /// `item.sharedPath`（記録済みのコピー先）をそのまま再利用するので、フォルダを作る先だけ
    /// 新レイアウトになり、**写真は旧パスに書かれ続ける**。フォルダごと動かして記録も
    /// 張り替えないと追いつかない。
    ///
    /// 実体の転送は起きない（配下ごと移動）。失敗した回は記録を進めない——記録だけ進めると
    /// クラウド上の実体を見失って全部コピーし直す事故になる（次回の反映で再試行）。
    ///
    /// - Returns: 移行後（または元のまま）のセット。
    private func migrateFolderIfNeeded(set: ShareSetLite, shareRoot: String,
                                       store: BackupStore, copier: DropboxShareCopier,
                                       token: String) async -> ShareSetLite {
        // ⚠️ 検査済みの印があれば何もしない。無いと**毎回の反映で旧配置を探し続ける**
        // （存在しないパスへの move が 1 セットにつき 1 往復・規約: 無いものを繰り返し探さない）。
        guard set.layoutVersion != ShareSet.currentLayoutVersion else { return set }
        let kind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
        let allNames = await store.allShareSets().map(\.folderName)
        // 種類が分からない（作成元不明の旧セット）なら名前は据え置き、置き場所だけ直す。
        let newName = ShareNaming.migratedFolderName(current: set.folderName, name: set.name,
                                                     kind: kind, existing: allNames)
            ?? set.folderName
        let device = BackupDeviceIdentity.currentFolderName()
        guard let desired = SharePlanning.setFolderPath(shareRoot: shareRoot,
                                                        folderName: newName,
                                                        deviceFolder: device) else { return set }

        /// 検査が済んだ印（移行不要だった場合も含む）。以後この探索は走らない。
        func markChecked() async -> ShareSetLite {
            await store.markShareSetLayoutCurrent(setID: set.id)
            return ShareSetLite(id: set.id, name: set.name, folderName: set.folderName,
                                createdAt: set.createdAt, sidecarChecksum: set.sidecarChecksum,
                                sourceKey: set.sourceKey,
                                layoutVersion: ShareSet.currentLayoutVersion)
        }

        // 旧レイアウトの候補（上から順に試す）。端末フォルダ以前は共有ルート直下だった。
        var candidates: [String] = []
        for path in [
            SharePlanning.setFolderPath(shareRoot: shareRoot, folderName: set.folderName,
                                        deviceFolder: device),
            SharePlanning.setFolderPath(shareRoot: shareRoot, folderName: set.folderName,
                                        deviceFolder: nil),
            SharePlanning.setFolderPath(shareRoot: shareRoot, folderName: newName,
                                        deviceFolder: nil),
        ] {
            guard let path, path.lowercased() != desired.lowercased(),
                  !candidates.contains(where: { $0.lowercased() == path.lowercased() })
            else { continue }
            candidates.append(path)
        }
        guard !candidates.isEmpty else { return await markChecked() }

        func adopt(movedFrom old: String) async -> ShareSetLite {
            await store.renameShareSet(setID: set.id, folderName: newName,
                                       oldPathPrefix: old, newPathPrefix: desired)
            return ShareSetLite(id: set.id, name: set.name, folderName: newName,
                                createdAt: set.createdAt, sidecarChecksum: nil,
                                sourceKey: set.sourceKey,
                                layoutVersion: ShareSet.currentLayoutVersion)
        }

        for old in candidates {
            switch await copier.moveFolder(from: old, to: desired, token: token) {
            case .moved:
                BackupLogger.info("Share: moved '\(old)' → '\(desired)'")
                return await adopt(movedFrom: old)
            case .destinationExists:
                // 移動先が既にある（`to/conflict/folder`）。move では永久に解決しないので
                // **移動先を正とする**——記録の接頭辞だけ付け替えて移行を終わらせる。
                //
                // ⚠️ これが無いと、反映のたびに 409 → 旧接頭辞のままの記録 → コピー先も旧フォルダ
                // （既にファイルがある＝全件 conflict）→ 「コピー失敗」で重複掃除もスキップ、という
                // 収束しない輪に入る（実機 diagnostics-64〜66 で copy=4297 が 3 ログとも同じ数字）。
                // 付け替えたあとは、移動先に既に在るファイルは**採用**され（ハッシュ一致）、
                // 足りないぶんだけサーバーサイドコピーで埋まる＝通常の収束経路に戻る。
                //
                // 旧フォルダは**消さない**（共有相手にも見えるユーザーのデータ。中身は次の反映で
                // 移動先へ作り直される）。残骸の掃除は人の判断に委ねるため、場所をログに残す。
                BackupLogger.info("Share: '\(desired)' already exists — adopting it as the set folder; "
                    + "the old folder '\(old)' is left as-is (delete it manually if unneeded)")
                return await adopt(movedFrom: old)
            case .failed:
                // 通信断・権限など。次回に持ち越す（他の候補も同じ理由で失敗する）。
                BackupLogger.error("Share: move '\(old)' → '\(desired)' failed — retrying next run")
                return set
            case .sourceMissing:
                continue   // その候補は存在しない。次の候補へ。
            }
        }

        // どの候補も実在しない＝まだ 1 度も反映していない。記録だけ現在のレイアウトへ。
        guard newName != set.folderName else { return await markChecked() }
        BackupLogger.info("Share: renamed '\(set.folderName)' → '\(newName)' (not yet on Dropbox)")
        return await adopt(movedFrom: candidates[0])
    }

    /// テスト用: 現在のファイル墓標。
    func fileTombstonesForTesting() -> [String: Date] {
        ShareSettingsKeys.deletedFileTombstones(account: accountFingerprint(), defaults)
    }

    /// 削除済みフォルダの後始末。**復活していたら消し直す**。
    ///
    /// 削除の直前まで走っていたコピージョブは、こちらがポーリングをやめてもサーバー側で
    /// 完走する（Dropbox にジョブ取り消しの API は無い）。完走すると消したフォルダが
    /// 戻ってくるが、記録は既に無いので誰の持ち物でもない孤児になる。猶予時間の間だけ
    /// 覚えておいて掃除し、期限切れの墓標は捨てる（無いものを探し続けない）。
    private func sweepDeletedFolders(copier: DropboxShareCopier, token: String) async {
        let account = accountFingerprint()
        let now = Date()

        var folders = ShareSettingsKeys.deletedFolderTombstones(account: account, defaults)
        if !folders.isEmpty {
            for (path, deletedAt) in folders {
                // 消し直す。既に無ければ not_found＝成功として扱われる。
                guard await copier.deleteBatch(paths: [path], token: token) else { continue }
                if now.timeIntervalSince(deletedAt) >= ShareSettingsKeys.deletedFolderGraceSeconds {
                    folders.removeValue(forKey: path)
                }
            }
            ShareSettingsKeys.setDeletedFolderTombstones(folders, account: account, defaults)
        }

        // 単枚の墓標（メンバーから外した写真の予定コピー先）も同じ規則で掃除する。
        var files = ShareSettingsKeys.deletedFileTombstones(account: account, defaults)
        guard !files.isEmpty else { return }
        let paths = Array(files.keys)
        for chunk in stride(from: 0, to: paths.count, by: 100).map({
            Array(paths[$0..<min($0 + 100, paths.count)])
        }) {
            guard await copier.deleteBatch(paths: chunk, token: token) else { continue }
            for path in chunk where now.timeIntervalSince(files[path] ?? now)
                >= ShareSettingsKeys.deletedFolderGraceSeconds {
                files.removeValue(forKey: path)
            }
        }
        ShareSettingsKeys.setDeletedFileTombstones(files, account: account, defaults)
    }

    /// 外した写真の**予定コピー先**に墓標を置く（まだコピーされていない分）。
    ///
    /// 予定先は `SharePlanning` と同じ規則（セットフォルダ直下・元のファイル名）で求める。
    /// 連番（"name 2.jpg"）まで再現はできないが、素の名前を押さえておけば
    /// 発行済みジョブが作る典型的なファイルは掃除できる。
    func addFileTombstones(for items: [ShareItemLite], setID: UUID,
                                   store: BackupStore) async {
        guard !items.isEmpty else { return }
        guard let set = await store.allShareSets().first(where: { $0.id == setID }),
              let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(defaults),
                folderName: set.folderName,
                deviceFolder: BackupDeviceIdentity.currentFolderName()) else { return }

        let localIDs = items.filter { $0.refKey.hasPrefix("L-") }.map { String($0.refKey.dropFirst(2)) }
        let backupRefs = await store.backupRefs(forLocalIdentifiers: localIDs)
        let account = accountFingerprint()
        var files = ShareSettingsKeys.deletedFileTombstones(account: account, defaults)
        let now = Date()
        for item in items {
            let source: String?
            if item.refKey.hasPrefix("C-") {
                source = String(item.refKey.dropFirst(2))
            } else {
                source = backupRefs[String(item.refKey.dropFirst(2))]?.dropboxPath
            }
            guard let source else { continue }
            let name = (source as NSString).lastPathComponent
            files["\(folder)/\(name)".lowercased()] = now
        }
        ShareSettingsKeys.setDeletedFileTombstones(files, account: account, defaults)
    }

    private func sync(set: ShareSetLite, shareRoot: String, store: BackupStore,
                      copier: DropboxShareCopier, token: String) async {
        let items = await store.shareItems(setID: set.id)
        guard !items.isEmpty else { return }
        guard let setFolder = SharePlanning.setFolderPath(
                shareRoot: shareRoot, folderName: set.folderName,
                deviceFolder: BackupDeviceIdentity.currentFolderName()) else {
            BackupLogger.error("Share sync: invalid folder name — skipping set")
            return
        }

        // フォルダを確保してから実在一覧を取る。一覧が取れない（通信断）ときは
        // このセットをスキップする（実在不明のまま再コピーすると autorename で重複を作る）。
        guard await copier.createFolder(path: setFolder, token: token) else {
            lastError = .folderPrepareFailed
            BackupLogger.error("Share sync: create_folder failed — \(setFolder)")
            return
        }
        guard let listing = await copier.listFolder(path: setFolder, token: token) else {
            lastError = .folderCheckFailed
            BackupLogger.error("Share sync: list_folder failed — \(setFolder)")
            return
        }
        let remoteFiles = listing.filter { !$0.isFolder }
            .map { SharePlanning.RemoteFile(pathLower: $0.pathLower, contentHash: $0.contentHash) }

        // 計画（純ロジック）: コピー / 採用 / 掃除 / バックアップ待ちを算出。
        let localIDs = items.filter { $0.refKey.hasPrefix("L-") }
            .map { String($0.refKey.dropFirst(2)) }
        let backupRefs = await store.backupRefs(forLocalIdentifiers: localIDs)
        // 計画の宛先組み立ても端末フォルダ込みのルートで行う（setFolder と一致させる）。
        let deviceRoot = (setFolder as NSString).deletingLastPathComponent
        let plan = SharePlanning.plan(items: items, backupByLocalID: backupRefs,
                                      shareRoot: deviceRoot, folderName: set.folderName,
                                      remoteFiles: remoteFiles)

        BackupLogger.info("Share sync: '\(set.folderName)' items=\(items.count) "
            + "copy=\(plan.copies.count) adopt=\(plan.adoptions.count) "
            + "waitingBackup=\(plan.waitingBackup.count) present=\(remoteFiles.count) "
            + "dupes=\(plan.duplicatesToDelete.count)")
        if !plan.waitingBackup.isEmpty {
            await store.updateShareItems(setID: set.id, updates: plan.waitingBackup.map {
                (refKey: $0, state: .waitingBackup, sourcePath: nil,
                 sharedPath: nil, sharedContentHash: nil)
            })
        }

        // 採用: 宛先が既に実在するもの（タイムアウト後に完了していたジョブの成果など）は
        // コピーせず記録だけ更新する＝リトライが冪等になる（diagnostics-52）。
        if !plan.adoptions.isEmpty {
            await store.updateShareItems(setID: set.id, updates: plan.adoptions.map {
                (refKey: $0.refKey, state: .copied, sourcePath: nil,
                 sharedPath: $0.sharedPathLower, sharedContentHash: $0.contentHash)
            })
        }

        // ⚠️ 掃除より**先に**コピーする（diagnostics-55）。逆順だと、コピーが失敗し続けている
        // 状態でも掃除だけが毎回走り、「削除 → 変更通知 → 反映 → また削除」の空回りになる
        // （実機で 2,226 → 1,710 件と削除し続けても収束しなかった）。掃除は**コピーが
        // 健全に終わったときだけ**行う。
        var copiedCount = 0
        var copyFailed = false
        // 1 回の反映で投げるコピーの上限。暴走の後始末は数千件になり得るが、一度に
        // 流すと API レート制限を誘発し、失敗 → 再試行 → さらに負荷、の悪循環になる。
        let copyBudget = min(plan.copies.count, Self.maxCopiesPerRun)
        if plan.copies.count > copyBudget {
            BackupLogger.info("Share sync: '\(set.folderName)' copying \(copyBudget) of \(plan.copies.count) this run (rest continues next run)")
            // 未コピーを大量に残したまま掃除しない（残りは次回に回す）。
            copyFailed = true
        }
        for chunk in stride(from: 0, to: copyBudget, by: Self.copyChunkSize).map({
            Array(plan.copies[$0..<min($0 + Self.copyChunkSize, copyBudget)])
        }) {
            let entries = chunk.map { (from: $0.fromPath, to: $0.toPath) }
            let result = await copier.copyBatch(entries: entries, token: token)
            // ⚠️ 「本処理が完全に成功した回だけ後始末する」が不変条件（diagnostics-55）。
            // リクエスト全体の失敗だけでなく、**エントリ単位の失敗**も失敗として扱う。
            if result == nil || result?.entries.contains(where: { $0 == nil }) == true {
                copyFailed = true
            }
            var updates: [(refKey: String, state: ShareItemState, sourcePath: String?,
                           sharedPath: String?, sharedContentHash: String?)] = []
            for (i, copy) in chunk.enumerated() {
                if let entry = result?.entries[i] ?? nil {
                    updates.append((refKey: copy.refKey, state: .copied,
                                    sourcePath: copy.fromPath,
                                    sharedPath: entry.pathLower,
                                    sharedContentHash: entry.contentHash))
                    copiedCount += 1
                } else {
                    updates.append((refKey: copy.refKey, state: .failed,
                                    sourcePath: copy.fromPath,
                                    sharedPath: nil, sharedContentHash: nil))
                }
            }
            await store.updateShareItems(setID: set.id, updates: updates)
        }
        if copiedCount > 0 {
            BackupLogger.info("Share: '\(set.folderName)' copied \(copiedCount)/\(plan.copies.count)")
        }

        // 掃除: 過去の autorename 暴走で生まれた重複（"name (N).ext"・どの記録にも属さず
        // 元名が実在するもの）を削除する。**コピーが失敗した回は掃除しない**——正規ファイルを
        // 作れていない状態で消すと、次回また同じものをコピーし直す空回りになる（diagnostics-55）。
        if copyFailed {
            if !plan.duplicatesToDelete.isEmpty {
                BackupLogger.info("Share sync: '\(set.folderName)' skipping cleanup of \(plan.duplicatesToDelete.count) duplicate(s) — copy failed this run")
            }
        } else if !plan.duplicatesToDelete.isEmpty {
            let budget = min(plan.duplicatesToDelete.count, Self.maxDeletesPerRun)
            BackupLogger.info("Share sync: '\(set.folderName)' deleting \(budget) of \(plan.duplicatesToDelete.count) duplicate file(s)")
            _ = await copier.deleteBatch(paths: Array(plan.duplicatesToDelete.prefix(budget)),
                                         token: token)
        }

        await updateSidecar(set: set, setFolder: setFolder, store: store,
                            copier: copier, token: token)
    }

    /// 解析サイドカーを組み立てて、内容が変わっていればアップロードする。
    private func updateSidecar(set: ShareSetLite, setFolder: String, store: BackupStore,
                               copier: DropboxShareCopier, token: String) async {
        guard let analysisSource else { return }
        let items = await store.shareItems(setID: set.id)
        let copiedItems = items.filter { $0.state == .copied && $0.sharedContentHash != nil }
        guard !copiedItems.isEmpty else { return }

        let payload = await analysisSource.analysisEntries(forRefKeys: copiedItems.map(\.refKey))
        var entriesByHash: [String: ShareSidecar.Entry] = [:]
        for item in copiedItems {
            guard let hash = item.sharedContentHash,
                  let entry = payload.entries[item.refKey] else { continue }
            entriesByHash[hash.lowercased()] = entry
        }
        guard !entriesByHash.isEmpty else { return }

        let file = ShareSidecar.File(versions: payload.versions, entries: entriesByHash)
        // JSON エンコード（sortedKeys）とチェックサムは数 MB 規模になり得るのでオフメインで。
        guard let (data, checksum) = await Task.detached(priority: .utility, operation: {
            ShareSidecar.encode(file).map { ($0, ShareSidecar.checksum($0)) }
        }).value else { return }
        guard checksum != set.sidecarChecksum else { return }   // 変化なし → 再アップロード不要

        let sidecarFolder = "\(setFolder)/\(ShareSidecar.subfolderName)"
        guard await copier.createFolder(path: sidecarFolder, token: token),
              await copier.uploadFile(data: data,
                                      to: ShareSidecar.sidecarPath(setFolderPath: setFolder),
                                      token: token) else { return }
        await store.setShareSidecarChecksum(setID: set.id, checksum: checksum)
        BackupLogger.info("Share: '\(set.folderName)' sidecar updated (\(entriesByHash.count) entries)")
    }
}
