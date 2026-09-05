import DropboxCore
import Foundation
import MosaicSupport

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

        // 配置の追いつき（フォルダ名の変更）は一覧を取る**前**に済ませる。
        var sets: [ShareSetLite] = []
        for set in await store.allShareSets() {
            sets.append(await migrateFolderIfNeeded(set: set, shareRoot: shareRoot,
                                                    store: store, copier: copier, token: token))
        }
        guard !sets.isEmpty else { lastSyncAt = Date(); await refresh(); return }

        // ADR-183: 共有ルートを**再帰で 1 回**一覧し、全セットの写真の実在とサイドカーの実在・内容
        // （content_hash）をまとめて知る。以前はセットごとに create_folder ＋ list_folder ＋
        // サイドカーの list_folder＝セット数 × 3 回の往復だった。
        // 取れない（通信断）ときは全部スキップ——実在不明のまま再コピーすると autorename で重複を作る。
        guard await copier.createFolder(path: shareRoot, token: token),
              let listing = await copier.listFolder(path: shareRoot, token: token, recursive: true) else {
            lastError = .folderCheckFailed
            BackupLogger.error("Share sync: list_folder(recursive) failed — \(shareRoot)")
            return
        }
        let remote = RemoteShareIndex(listing: listing)

        for set in sets {
            // 途中でユーザーが削除操作を始めたら、そこで止める（続きは次回の反映で拾う）。
            if isMutating || Task.isCancelled {
                needsAnotherPass = true
                break
            }
            await sync(set: set, shareRoot: shareRoot, store: store,
                       copier: copier, token: token, remote: remote)
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
        // ⚠️ 検査済みの印があれば何もしない（規約: 無いものを繰り返し探さない）。
        guard set.layoutVersion != ShareSet.currentLayoutVersion else { return set }

        // ADR-175: 配置が `/MosaicShare/<端末>/…` から `/MosaicPhotos/<端末>/Share/…` へ変わった。
        // **旧フォルダは動かさない**（ユーザー判断＝既存データは移行しない）。
        // 代わりに、このセットの記録を「未コピー」へ戻して**新配置へコピーし直す**。
        // 種類の接頭辞（`People-` 等）が無い旧々セットは、ついでに名前も付け直す。
        let kind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
        let allNames = await store.allShareSets().map(\.folderName)
        let newName = ShareNaming.migratedFolderName(current: set.folderName, name: set.name,
                                                     kind: kind, existing: allNames)
            ?? set.folderName
        await store.resetShareSetForRelayout(setID: set.id, folderName: newName)
        BackupLogger.info("Share: '\(set.folderName)' → '\(newName)' re-created under the new layout "
                          + "(old folder left in place)")
        Diagnostics.mark("share: 配置変更のため '\(set.name)' を新しい場所へコピーし直します（旧フォルダは残します）")
        return ShareSetLite(id: set.id, name: set.name, folderName: newName,
                            createdAt: set.createdAt, sidecarChecksum: nil,
                            sourceKey: set.sourceKey,
                            layoutVersion: ShareSet.currentLayoutVersion)
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

        // 単枚の墓標（メンバーから外した写真の予定コピー先）。
        //
        // ⚠️ **時間で消さない**（ADR-172）。発行済みの copy_batch はクライアントが諦めても
        // サーバー側で走り続ける。猶予（15 分）で墓標を捨てると、その後にジョブが完走した場合
        // **外したはずの写真が共有フォルダに残り続ける**——記録には無いので、以後どの反映でも
        // 掃除されない（家族には見えたまま）。
        // 消してよいのは「**実在しないことを確かめられた**」ときだけにする。
        var files = ShareSettingsKeys.deletedFileTombstones(account: account, defaults)
        guard !files.isEmpty else { return }
        let paths = Array(files.keys)
        for chunk in stride(from: 0, to: paths.count, by: 100).map({
            Array(paths[$0..<min($0 + 100, paths.count)])
        }) {
            guard await copier.deleteBatch(paths: chunk, token: token) else { continue }
        }
        // 削除を投げたうえで、**親フォルダを 1 回ずつ見て不在を確認**する。
        // 一覧が取れない（通信断・フォルダ自体が無い）ときは消さずに残す＝次の反映で再確認。
        var confirmedGone = Set<String>()
        var parentFolders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        parentFolders.remove("")
        for folder in parentFolders {
            guard let listing = await copier.listFolder(path: folder, token: token) else { continue }
            let present = Set(listing.map { $0.pathLower })
            for path in paths where path.hasPrefix(folder + "/") && !present.contains(path) {
                confirmedGone.insert(path)
            }
        }
        for path in confirmedGone { files.removeValue(forKey: path) }
        // 墓標が無限に増えないよう上限だけ設ける（古い順に捨てる）。確認できないまま
        // これを超えるのは異常事態なので、記録に残す。
        if files.count > ShareSettingsKeys.maxFileTombstones {
            let dropped = files.count - ShareSettingsKeys.maxFileTombstones
            for (path, _) in files.sorted(by: { $0.value < $1.value }).prefix(dropped) {
                files.removeValue(forKey: path)
            }
            Diagnostics.mark("share: 墓標が上限を超えたため古い \(dropped) 件を破棄しました")
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
                deviceFolder: nil /* ADR-175: shareRoot は端末フォルダ込み */) else { return }

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
                      copier: DropboxShareCopier, token: String, remote: RemoteShareIndex) async {
        let items = await store.shareItems(setID: set.id)
        guard !items.isEmpty else { return }
        guard let setFolder = SharePlanning.setFolderPath(
                shareRoot: shareRoot, folderName: set.folderName,
                deviceFolder: nil /* ADR-175: shareRoot は端末フォルダ込み */) else {
            BackupLogger.error("Share sync: invalid folder name — skipping set")
            return
        }

        // セットのフォルダが無ければ作る（一覧に無い＝初回か外部削除）。実在一覧は共有ルートの
        // 再帰一覧（ADR-183）から切り出す＝セットごとの往復は無い。
        if !remote.hasFolder(setFolder) {
            guard await copier.createFolder(path: setFolder, token: token) else {
                lastError = .folderPrepareFailed
                BackupLogger.error("Share sync: create_folder failed — \(setFolder)")
                return
            }
        }
        let remoteFiles = remote.photoFiles(inSetFolder: setFolder)
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

        // ADR-183: サイドカー（シャード）は**コピーの前に**、いまコピー済みの分で揃える。
        // コピーは 500 枚/回・100 枚ごとのサーバー側ジョブ待ちで数分かかるので、後回しだと
        // 「反映を押してもサイドカーが何分も更新されない」（実フィードバック: 検証に時間がかかる）。
        // 差分はシャード単位なので二度組んでも軽い。今回コピーした分は末尾でもう一度反映する。
        await updateSidecar(set: set, setFolder: setFolder, store: store,
                            copier: copier, token: token,
                            remoteSidecars: remote.sidecarFiles(inSetFolder: setFolder))

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

        // 今回コピーした分のエントリを足す（上で置いたシャードは一覧に無いので、遠隔の状態は
        // 「上げた直後の hash」で補う＝同じものを上げ直さない）。
        if copiedCount > 0 {
            let justUploaded = uploadedShardNames
            let names = Set(justUploaded.map(\.name))
            let remoteNow = remote.sidecarFiles(inSetFolder: setFolder).filter { !names.contains($0.name) }
                + justUploaded.map {
                    DropboxShareCopier.ListedFile(pathLower: "", name: $0.name, rev: nil,
                                                  contentHash: $0.hash, isFolder: false)
                }
            await updateSidecar(set: set, setFolder: setFolder, store: store,
                                copier: copier, token: token, remoteSidecars: remoteNow)
        }
    }

    /// 解析サイドカーを**シャード単位**で同期する（ADR-183）。
    ///
    /// 状態は持たない: 「上げるべきか」は共有ルートの再帰一覧にある各シャードの `content_hash` と、
    /// 手元で組んだシャードの `content_hash`（同じ計算・`DropboxContentHash`）の比較だけで決まる。
    /// - 手元にあって遠隔に無い／内容が違う → アップロード
    /// - 遠隔にあって手元に無い（シャードが空になった）→ 削除
    /// - 旧形式 `analysis-v1.json` が残っていれば削除（受信側はシャードを読む）
    /// 消されたサイドカーの復元（ADR-166）は「遠隔に無い → 上げる」に自然に含まれる。
    private func updateSidecar(set: ShareSetLite, setFolder: String, store: BackupStore,
                               copier: DropboxShareCopier, token: String,
                               remoteSidecars: [DropboxShareCopier.ListedFile]) async {
        uploadedShardNames.removeAll()
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

        // シャードのエンコードと content_hash は数 MB 規模になり得るのでオフメインで。
        let versions = payload.versions
        let local: [String: (data: Data, hash: String)] = await Task.detached(priority: .utility) {
            var out: [String: (data: Data, hash: String)] = [:]
            for (shard, file) in ShareSidecar.shards(versions: versions, entries: entriesByHash) {
                guard let data = ShareSidecar.encode(file) else { continue }
                out[shard] = (data, DropboxContentHash.hash(of: data))
            }
            return out
        }.value

        let plan = ShareSidecarPlanning.plan(local: local.mapValues(\.hash),
                                             remote: remoteSidecars.map {
                                                 ShareSidecarPlanning.RemoteFile(name: $0.name, contentHash: $0.contentHash)
                                             })
        guard !plan.upload.isEmpty || !plan.delete.isEmpty else { return }

        let sidecarFolder = "\(setFolder)/\(ShareSidecar.subfolderName)"
        if !plan.upload.isEmpty {
            guard await copier.createFolder(path: sidecarFolder, token: token) else { return }
        }
        var uploaded = 0
        for shard in plan.upload.sorted() {
            guard let entry = local[shard] else { continue }
            if await copier.uploadFile(data: entry.data, to: ShareSidecar.shardPath(setFolderPath: setFolder, shard: shard),
                                       token: token) {
                uploaded += 1
                uploadedShardNames.append((name: ShareSidecar.shardFileName(shard), hash: entry.hash))
            }
        }
        if !plan.delete.isEmpty {
            _ = await copier.deleteBatch(paths: plan.delete.map { "\(sidecarFolder)/\($0)" }, token: token)
        }
        if uploaded > 0 || !plan.delete.isEmpty {
            let line = "Share: '\(set.folderName)' sidecar shards +\(uploaded) -\(plan.delete.count) "
                + "(\(entriesByHash.count) entries in \(local.count) shards)"
            BackupLogger.info(line)
            Diagnostics.mark(line)   // Release でも実機ログに残す（検証の目印）
        }
    }
}

/// 共有ルートの再帰一覧を、セットごとの「写真の実在」と「サイドカーの実在」に切り出す（ADR-183）。
struct RemoteShareIndex {
    private let folders: Set<String>
    private let files: [DropboxShareCopier.ListedFile]

    init(listing: [DropboxShareCopier.ListedFile]) {
        folders = Set(listing.filter(\.isFolder).map(\.pathLower))
        files = listing.filter { !$0.isFolder }
    }

    func hasFolder(_ path: String) -> Bool { folders.contains(path.lowercased()) }

    /// セットフォルダ**直下**の写真（サイドカーのフォルダ配下は含めない）。
    func photoFiles(inSetFolder setFolder: String) -> [DropboxShareCopier.ListedFile] {
        let prefix = setFolder.lowercased() + "/"
        return files.filter { file in
            guard file.pathLower.hasPrefix(prefix) else { return false }
            return !file.pathLower.dropFirst(prefix.count).contains("/")
        }
    }

    /// セットのサイドカーファイル（シャード・旧形式）。
    func sidecarFiles(inSetFolder setFolder: String) -> [DropboxShareCopier.ListedFile] {
        let prefix = setFolder.lowercased() + "/" + ShareSidecar.subfolderName + "/"
        return files.filter { $0.pathLower.hasPrefix(prefix) && ShareSidecar.isSidecarFileName($0.name) }
    }
}

/// サイドカーのシャードの差分計画（純ロジック・テスト対象）。
public enum ShareSidecarPlanning {
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
    ///   - remote: `.mosaic-share` にあるサイドカーファイル。
    public static func plan(local: [String: String], remote: [RemoteFile]) -> Plan {
        var plan = Plan()
        var remoteByName: [String: String?] = [:]
        for file in remote { remoteByName[file.name] = file.contentHash }
        for (shard, hash) in local {
            let name = ShareSidecar.shardFileName(shard)
            if remoteByName[name] != hash { plan.upload.append(shard) }
        }
        let localNames = Set(local.keys.map(ShareSidecar.shardFileName))
        for file in remote where !localNames.contains(file.name) {
            plan.delete.append(file.name)   // 空になったシャード、または旧形式
        }
        plan.upload.sort()
        plan.delete.sort()
        return plan
    }
}
