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
// セットごとの手順は `ShareSyncEngine+SetSync.swift`（段に分けてある）。
// **記録を見て食い違いを直す**のではなく、**望ましい姿を作って差分を取る**。
// だから採用・自己修復・ドリフト検知・墓標・残骸掃除がどれも要らない。

extension ShareSyncEngine {

    /// 全セットを反映する（コピー・掃除・解析データ更新）。
    /// ⚠️ アプリからは `sync(_:)`（起こし方ごとの決まりを通る入口）を呼ぶ。これは 1 回ぶんの本体。
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

    /// 走行中の反映を**次の区切りで**止める（夜間の窓の期限切れ・diagnostics-109）。
    ///
    /// 反映は構造化されていない Task で走るので、窓の `cancel()` は届かない。期限切れの窓の
    /// 反映は投げた通信ごと 30 分止まり、次の窓の頭で失敗と飢餓を出していた。
    /// ⚠️ **通信の途中では止めない**（`Task.cancel` にしない）。区切りは「セットとセットの間」
    /// 「コピーの塊の間」「原本への問い合わせの間」の 3 つで、止まった回は**消さない**
    /// （そのセットの掃除・フォルダの掃除・再走をしない）。次の回が続きから決め直す。
    /// 前面復帰では呼ばない（利用者が始めた反映と区別できない・バックアップと同じ扱い）。
    public func stopAtNextBreak() {
        guard isSyncing, !stopRequested else { return }
        stopRequested = true
        Diagnostics.mark("share sync: 区切りで止めるよう頼んだ（窓の期限切れ）")
    }

    /// 区切りで止まるべきか。
    var shouldStopAtBreak: Bool { stopRequested || Task.isCancelled }

    private func performSync() async {
        defer {
            isSyncing = false
            stopRequested = false
        }
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
        var finishedSets = 0
        for set in sets {
            guard !shouldStopAtBreak else { break }
            await sync(set: set, shareRoot: shareRoot, store: store,
                       copier: copier, token: token, remote: remote, removal: removal)
            await refresh(totals: totals)   // 進捗（共有済み N/M）を UI へ（変化なしなら無通知）
            finishedSets += 1
        }
        // ⚠️ 止まった回は**フォルダの掃除をしない**（消す判断は材料が揃った回だけ）。再走もしない
        // ——止めたのは窓が尽きたからで、続きは次の回（次の窓・バックアップ後・起動）が拾う。
        if shouldStopAtBreak {
            needsAnotherPass = false
            Diagnostics.mark("share sync: 区切りで止めた（\(finishedSets)/\(sets.count) セットの後・掃除は次の回）")
            await refresh()
            return
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

    /// 解析データを**シャード単位**で同期する（ADR-183）。
    ///
    /// 状態は持たない: 「上げるべきか」は共有ルートの再帰一覧にある各シャードの `content_hash` と、
    /// 手元で組んだシャードの `content_hash`（同じ計算・`DropboxContentHash`）の比較だけで決まる。
    /// 消された解析データの復元（ADR-166）は「遠隔に無い → 上げる」に自然に含まれる。
    ///
    /// ⚠️ 解析データのキーは**写真の content_hash**（受信側が自分の同期一覧と突合するため）。
    /// 共有フォルダに実際に置かれている写真のぶんだけ載せる——まだコピーしていない写真の
    /// 解析結果を載せても、受信側には突合する相手が居ない。
    func updateAnalysisData(set: ShareSetLite, setFolder: String, items: [ShareItemLite],
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
