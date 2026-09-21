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
        let sets = await store.allShareSets()

        // ⚠️ 共有ルートは**無いときだけ**作る。毎回投げると 1 往復を捨て続けることになる
        //（409＝既存で無害だが、落ち着いた反映は 1 往復も書かないのが正しい）。
        let listing: [DropboxShareCopier.ListedFile]
        if let fetched = await copier.listFolder(path: shareRoot, token: token, recursive: true) {
            listing = fetched
        } else if !sets.isEmpty, await copier.createFolder(path: shareRoot, token: token) {
            // ルートがまだ無かった（初回）。作れたなら空として進む。
            listing = []
        } else {
            lastError = .folderCheckFailed
            BackupLogger.error("Share sync: list_folder(recursive) failed — \(shareRoot)")
            return
        }
        let remote = RemoteShareIndex(listing: listing)

        for set in sets {
            guard !Task.isCancelled else {
                needsAnotherPass = true
                break
            }
            await sync(set: set, shareRoot: shareRoot, store: store,
                       copier: copier, token: token, remote: remote)
            await refresh()   // セットごとに進捗（共有済み N/M）を UI へ反映（変化なしなら無通知）
        }
        // ⚠️ **フォルダの掃除は最後**（紛らわしい名前のテストが捕まえた）。
        // 先にやると、**コピー元が掃除対象のフォルダに在る**場合に元を消してからコピーする
        // ことになり、コピーが永久に失敗する（クラウド写真は共有ルートの中にも在り得る）。
        // 掃除は「どのセットも持たないフォルダを消す」だけなので、後回しにしても
        // 判断は変わらない——変わるのは「元を取り終わってから消す」ことだけ。
        await sweepUnwantedFolders(sets: sets, shareRoot: shareRoot, remote: remote,
                                   copier: copier, token: token)

        lastSyncAt = Date()
        await refresh()

        // 走行中に来た要求をここで 1 回だけ消化する（無限再帰にならないよう旗を先に落とす）。
        if needsAnotherPass {
            needsAnotherPass = false
            isSyncing = false
            await syncNow()
        }
    }

    /// **望ましくないフォルダを消す**（ADR-209）。
    ///
    /// 共有ルートの直下にあってよいのは、いまあるセットのフォルダだけ。それ以外は
    /// - 削除したセットの残骸
    /// - 名前を変えた前のフォルダ
    /// - 消したあとに遅れて完走したコピーが復活させたフォルダ
    /// のいずれかで、どれも消してよい。
    ///
    /// ⚠️ これが**墓標を不要にした**（旧実装は「消したフォルダ」を 15 分覚えて消し直していた。
    /// Dropbox にジョブ取り消しの API が無いため、発行済みのコピーが後から完走するのを
    /// 待ち構える必要があった）。差分なら、いつ復活しても次の反映で消える。
    private func sweepUnwantedFolders(sets: [ShareSetLite], shareRoot: String,
                                      remote: RemoteShareIndex,
                                      copier: DropboxShareCopier, token: String) async {
        let wanted = Set(sets.compactMap {
            SharePlanning.setFolderPath(shareRoot: shareRoot, folderName: $0.folderName,
                                        deviceFolder: nil)?.lowercased()
        })
        let unwanted = remote.directSubfolders(of: shareRoot).filter { !wanted.contains($0) }
        guard !unwanted.isEmpty else { return }
        let budget = Array(unwanted.sorted().prefix(Self.maxDeletesPerRun))
        BackupLogger.info("Share sync: removing \(budget.count) folder(s) that no set owns")
        _ = await copier.deleteBatch(paths: budget, token: token)
    }

    private func sync(set: ShareSetLite, shareRoot: String, store: BackupStore,
                      copier: DropboxShareCopier, token: String, remote: RemoteShareIndex) async {
        let items = await store.shareItems(setID: set.id)
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
            guard await copier.createFolder(path: setFolder, token: token) else {
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
        let backupRefs = await store.backupRefs(forLocalIdentifiers: localIDs)
        let plan = SharePlanning.plan(items: items, backupByLocalID: backupRefs,
                                      cloudHashByPath: cloudSourceHashProvider(),
                                      setFolder: setFolder, remoteFiles: remoteFiles)

        BackupLogger.info("Share sync: '\(set.folderName)' items=\(items.count) "
            + "copy=\(plan.copies.count) present=\(plan.present) "
            + "delete=\(plan.deletions.count) waitingBackup=\(plan.waitingBackup.count)")
        if plan.skippedDeletionsForSafety {
            // ⚠️ 黙って何もしない状態を作らない（実機で「詰まっているのにログが無い」を何度も踏んだ）。
            Diagnostics.mark("share: '\(set.name)' 元が 1 件も解決できないため掃除を見送りました "
                             + "（メンバー \(items.count) 件）")
        }

        // 解析データは**コピーの前に**、いま置かれている分で揃える（ADR-183）。
        // コピーは数分かかるので、後回しだと「反映を押しても解析データが何分も更新されない」。
        let presentPaths = Set(remoteFiles.map(\.pathLower))
            .subtracting(plan.deletions)
        await updateAnalysisData(set: set, setFolder: setFolder, items: items,
                                 presentPathsLower: presentPaths, sourceByRefKey: plan.sourceByRefKey,
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

        // 掃除。**コピーの成否に関係なく消してよい**（ADR-209）——消す対象は「望ましくない
        // 名前のファイル」で、コピーが失敗しても望ましくないことは変わらない。
        // ⚠️ 旧実装は「コピーが全部成功した回だけ掃除」だった。宛先名を採番していた頃は
        // 掃除対象が「正規ファイルの重複」だったので、正規が作れていない状態で消すと
        // 空回りになったため（diagnostics-55）。いまは対象が別物なのでその制約は要らない。
        if !plan.deletions.isEmpty {
            let deleteBudget = Array(plan.deletions.prefix(Self.maxDeletesPerRun))
            BackupLogger.info("Share sync: '\(set.folderName)' deleting \(deleteBudget.count) stale file(s)")
            _ = await copier.deleteBatch(paths: deleteBudget, token: token)
        }

        await store.recordShareSyncCounts(setID: set.id,
                                          present: plan.present + copied,
                                          waiting: plan.waitingBackup.count)

        // コピーした分の解析データを足す（一覧はコピー前のものなので、ここで補う）。
        if copied > 0 {
            let nowPresent = presentPaths.union(copiedDestinations)
            await updateAnalysisData(set: set, setFolder: setFolder, items: items,
                                     presentPathsLower: nowPresent, sourceByRefKey: plan.sourceByRefKey,
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
            guard await copier.createFolder(path: analysisFolder, token: token) else { return }
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
