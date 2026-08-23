import DropboxCore
import Foundation
import Observation

/// 送信側の解析サイドカー供給 seam。実体はアプリ（Composition Root）が
/// AutoAlbumCore / FaceCore のストアから組み立てて注入する。
public protocol ShareAnalysisSource: AnyObject {
    /// refKey 群の解析エントリ（キーは refKey・値はサイドカーの 1 エントリ）と各セクションの版。
    @MainActor func analysisEntries(forRefKeys refKeys: [String]) async
        -> (versions: ShareSidecar.Versions, entries: [String: ShareSidecar.Entry])
}

/// 共有セットの**作成元**（人物・グループ・アルバム）の現在のメンバーを解決する seam。
/// 実体はアプリ（Composition Root）が `PeopleEngine` / `AutoAlbumEngine` を見て実装する。
/// 共有セットは作成時のスナップショットなので、これを使って「今の内容に更新」できる。
public protocol ShareSourceResolver: AnyObject {
    /// 作成元の現在の写真キー。作成元が既に無ければ nil（＝孤児セット）。
    @MainActor func currentMembers(for key: ShareSourceKey) async -> [String]?
}

/// 家族共有（共有セット）のオーケストレーション（ADR-112）。
///
/// 「共有はバックアップの射影」——選択した写真をサーバーサイドコピーで共有フォルダへ投影し、
/// 解析結果（タグ・CLIP・顔）をサイドカーとして同梱する。正本（バックアップ・原本）には
/// 一切手を触れない。削除系（セット削除・単枚解除）はユーザー操作起点のみ。
@MainActor
@Observable
public final class ShareSyncEngine {

    /// UI 表示用のセット概要。
    public struct SetSummary: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let name: String
        public let folderName: String
        public let createdAt: Date
        public var sourceKey: String?
        public var total = 0
        public var copied = 0
        public var waitingBackup = 0
        public var failed = 0
    }

    public private(set) var sets: [SetSummary] = []
    public private(set) var isSyncing = false
    /// 走行中に来た反映要求（終わったら 1 回だけ再走する）。
    @ObservationIgnored private var needsAnotherPass = false
    /// 削除系（セット削除・単枚解除）の実行中フラグ。反映と**相互排他**にする。
    ///
    /// ⚠️ 排他しないと「削除 → 走行中の反映が続きのチャンクをコピー」で、消したはずの
    /// 共有フォルダが写真つきで復活し、記録が無いので二度と掃除されない（レビュー指摘）。
    @ObservationIgnored private var isMutating = false
    public private(set) var lastSyncAt: Date?
    public private(set) var lastError: SyncError?

    /// 反映の失敗種別。**表示側で翻訳する**ため文言をここに持たない
    /// （規約: 動的 String は verbatim＝未翻訳になる）。
    public enum SyncError: Equatable, Sendable {
        case notConnected
        case folderPrepareFailed
        case folderCheckFailed
        case folderRemoveFailed
        case invalidFolderName
    }

    @ObservationIgnored private let tokenProvider: AccessTokenProvider
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private let storeProvider: @MainActor () async -> BackupStore
    /// 解析サイドカーの供給元（未設定なら写真のみ共有）。
    @ObservationIgnored public weak var analysisSource: ShareAnalysisSource?
    /// 作成元の現在メンバー解決（未設定なら「今の内容に更新」を出さない）。
    @ObservationIgnored public weak var sourceResolver: ShareSourceResolver?
    /// 非同期ジョブのポーリング設定（テストで短縮する。本番は既定値）。
    @ObservationIgnored var pollIntervalNs: UInt64?
    @ObservationIgnored var maxPollAttempts: Int?

    /// 生成した copier に、テスト用のポーリング設定を反映する。
    private func makeCopier() -> DropboxShareCopier {
        var copier = DropboxShareCopier(httpClient: httpClient)
        if let pollIntervalNs { copier.pollIntervalNs = pollIntervalNs }
        if let maxPollAttempts { copier.maxPollAttempts = maxPollAttempts }
        return copier
    }

    /// 1 回の copy_batch に載せる最大エントリ数。
    private static let copyChunkSize = 100
    /// 1 回の反映で投げるコピー / 削除の上限（diagnostics-55）。暴走の後始末は数千件に
    /// なり得るが、一度に流すと API レート制限を誘発し、失敗→再試行でさらに負荷が増える。
    /// 残りは次回の反映で続きから片付ける（計画は毎回実在照合するので取りこぼさない）。
    private static let maxCopiesPerRun = 500
    private static let maxDeletesPerRun = 500

    public init(tokenProvider: AccessTokenProvider,
                storeProvider: @escaping @MainActor () async -> BackupStore,
                httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = tokenProvider
        self.storeProvider = storeProvider
        self.httpClient = httpClient
    }

    // MARK: - セット操作（UI から呼ぶ）

    /// セット概要を読み直す（ハブ表示用）。
    /// ⚠️ 集計は **1 回の fetch**（`shareItemCounts`）で行う。以前はセットごとに
    /// 全アイテムを引いており、セット N 個 × 数千アイテムの N+1 クエリになっていた。
    /// また **内容が同じなら代入しない**（`@Observable` は代入だけで購読ビューを
    /// 無効化するので、ホーム全体の再評価が無駄に走る・ADR-95 と同じ理由）。
    public func refresh() async {
        let store = await storeProvider()
        let all = await store.allShareSets()
        let counts = await store.shareItemCounts()
        let summaries: [SetSummary] = all.map { set in
            var summary = SetSummary(id: set.id, name: set.name,
                                     folderName: set.folderName, createdAt: set.createdAt)
            summary.sourceKey = set.sourceKey
            if let c = counts[set.id] {
                summary.total = c.total
                summary.copied = c.copied
                summary.waitingBackup = c.waitingBackup
                summary.failed = c.failed
            }
            return summary
        }
        guard summaries != sets else { return }
        sets = summaries
    }

    /// 共有セットが 1 つでもあるか（存在判定のためだけに全件を引かない）。
    public func hasAnySet() async -> Bool {
        await storeProvider().shareSetCount() > 0
    }

    /// セットを作成（または**同じ対象／同名の既存セットを更新**）して即時反映を試みる。
    ///
    /// ⚠️ 同じ対象を 2 度共有したときに**別セットを作らない**。作ると Dropbox 上に
    /// 「名前 2」フォルダができ、**同じ写真がもう一組コピーされる**（容量が倍になる）。
    /// ピープルグループを解除して同じ名前で作り直すと ID が変わるため、ID だけでなく
    /// **表示名でも既存セットを探す**（実フィードバック）。
    @discardableResult
    public func createSet(name: String, refKeys: [String], sourceKey: String? = nil) async -> UUID? {
        let store = await storeProvider()
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allSets = await store.allShareSets()

        // 既存セットの再利用: (1) 作成元が完全一致 → (2) **同じ種類**かつ同じ表示名、の順。
        //
        // ⚠️ (2) で種類を見るのが要点。AI アルバム「◯◯」とピープルグループ「◯◯」のように
        // **別物に同じ名前**を付けることは普通にあり、名前だけで再利用すると
        // 片方を共有したつもりがもう片方の共有を書き換えてしまう（実フィードバック）。
        let requestedKind = sourceKey.flatMap(ShareSourceKey.init)?.kind
        let existingSet = allSets.first { $0.sourceKey != nil && $0.sourceKey == sourceKey }
            ?? allSets.first { set in
                guard !displayName.isEmpty, set.name == displayName else { return false }
                let existingKind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
                // 旧セット（種類不明）は、種類の判別ができないので名前一致で再利用してよい。
                return existingKind == nil || existingKind == requestedKind
            }
        if let existingSet {
            let updated = await updateSetMembers(setID: existingSet.id, refKeys: refKeys,
                                                 sourceKey: sourceKey, store: store)
            BackupLogger.info("Share: reusing set '\(existingSet.folderName)' "
                + "(+\(updated.added) / -\(updated.removed) items)")
            await refresh()
            scheduleSync()
            return existingSet.id
        }

        let folderName = ShareNaming.sanitize(name, existing: allSets.map(\.folderName))
        let set = await store.createShareSet(
            name: displayName.isEmpty ? folderName : displayName, folderName: folderName,
            sourceKey: sourceKey)
        _ = await store.addShareItems(setID: set.id, refKeys: refKeys)
        BackupLogger.info("Share: created set '\(folderName)' with \(refKeys.count) items")
        await refresh()
        // 反映（ネットワーク往復・コピー・サイドカー生成）はバックグラウンドで行う。
        // ここで待つと作成シートが反映完了まで閉じられず UI が固まって見える（実フィードバック）。
        scheduleSync()
        return set.id
    }

    /// 既存セットのメンバーを **今の内容へ合わせる**（追加＋除外）。共有側の実ファイル削除は
    /// 除外分だけ行い、残りは次の反映が面倒を見る。作成元キーも最新に更新する。
    @discardableResult
    public func updateSetMembers(setID: UUID, refKeys: [String], sourceKey: String? = nil,
                                 store: BackupStore? = nil) async -> (added: Int, removed: Int) {
        let resolvedStore: BackupStore
        if let store { resolvedStore = store } else { resolvedStore = await storeProvider() }
        let store = resolvedStore
        let wanted = Set(refKeys)
        let current = await store.shareItems(setID: setID)
        let obsolete = current.filter { !wanted.contains($0.refKey) }

        if !obsolete.isEmpty {
            // 共有フォルダ側の実ファイルも消す（記録だけ消すと孤児ファイルが残る）。
            let paths = obsolete.compactMap(\.sharedPath)
            if !paths.isEmpty, let token = try? await tokenProvider.freshAccessToken() {
                _ = await makeCopier().deleteBatch(paths: paths, token: token)
            }
            await store.removeShareItems(setID: setID, refKeys: obsolete.map(\.refKey))
        }
        let added = await store.addShareItems(setID: setID, refKeys: refKeys)
        if let sourceKey { await store.setShareSourceKey(setID: setID, sourceKey: sourceKey) }
        return (added, obsolete.count)
    }

    /// 反映をバックグラウンドで開始する（進捗はハブの isSyncing / セット状態で見える）。
    private func scheduleSync() {
        Task { await syncNow() }
    }

    /// 既存セットへ写真を追加して反映する。追加できた件数を返す。
    @discardableResult
    public func addItems(setID: UUID, refKeys: [String]) async -> Int {
        let store = await storeProvider()
        let added = await store.addShareItems(setID: setID, refKeys: refKeys)
        if added > 0 {
            await refresh()
            scheduleSync()
        }
        return added
    }

    /// セットを削除する（共有フォルダごと）。リモート削除に失敗したら記録は残す（再試行可能）。
    public func deleteSet(id: UUID) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        await waitForSyncToPause()
        guard let token = try? await tokenProvider.freshAccessToken() else {
            lastError = .notConnected
            return false
        }
        let store = await storeProvider()
        guard let set = await store.allShareSets().first(where: { $0.id == id }) else { return true }
        // ⚠️ 不正なフォルダ名（空・区切り・親参照）では**絶対に削除しない**。
        // 空名を許すと共有ルートごと消える。記録だけ消して手動対応に委ねる。
        guard let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(), folderName: set.folderName,
                deviceFolder: BackupDeviceIdentity.currentFolderName()) else {
            BackupLogger.error("Share: refusing to delete set with invalid folder name")
            lastError = .invalidFolderName
            return false
        }
        let copier = makeCopier()
        guard await copier.deleteBatch(paths: [folder], token: token) else {
            lastError = .folderRemoveFailed
            return false
        }
        await store.deleteShareSet(id: id)
        BackupLogger.info("Share: deleted set '\(set.folderName)'")
        await refresh()
        return true
    }

    /// 写真をセットから外す（コピー済みなら共有側ファイルも削除）。
    public func removeItems(setID: UUID, refKeys: [String]) async {
        isMutating = true
        defer { isMutating = false }
        await waitForSyncToPause()
        let store = await storeProvider()
        let items = await store.shareItems(setID: setID)
        let targets = items.filter { refKeys.contains($0.refKey) }
        let remotePaths = targets.compactMap(\.sharedPath)
        if !remotePaths.isEmpty, let token = try? await tokenProvider.freshAccessToken() {
            let copier = makeCopier()
            _ = await copier.deleteBatch(paths: remotePaths, token: token)
        }
        await store.removeShareItems(setID: setID, refKeys: refKeys)
        await refresh()
        scheduleSync()   // サイドカーから外した分を反映
    }

    /// 反映が走っていれば、区切り（次のセットの境目）まで待つ。
    /// `isMutating` を見て反映側が自発的に止まるので、ここは短時間で抜ける。
    /// 保険として上限を設け、待ち続けて UI を固めない。
    private func waitForSyncToPause(timeoutMs: Int = 3000) async {
        var waited = 0
        while isSyncing, waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
    }

    /// 作成元の**現在の内容**にセットを合わせ直す（追加＋除外＋反映）。
    /// 戻り値は (追加, 除外)。作成元が解決できない（孤児セット）なら nil。
    @discardableResult
    public func refreshFromSource(setID: UUID) async -> (added: Int, removed: Int)? {
        guard let resolver = sourceResolver else { return nil }
        let store = await storeProvider()
        guard let set = await store.allShareSets().first(where: { $0.id == setID }),
              let key = set.sourceKey.flatMap(ShareSourceKey.init),
              let members = await resolver.currentMembers(for: key) else { return nil }
        let result = await updateSetMembers(setID: setID, refKeys: members, store: store)
        BackupLogger.info("Share: refreshed '\(set.folderName)' from source (+\(result.added) / -\(result.removed))")
        await refresh()
        scheduleSync()
        return result
    }

    /// このセットの作成元が現存するか（孤児セットの判定・UI 表示用）。
    public func canRefreshFromSource(_ set: SetSummary) async -> Bool {
        guard let resolver = sourceResolver,
              let key = set.sourceKey.flatMap(ShareSourceKey.init) else { return false }
        return await resolver.currentMembers(for: key) != nil
    }

    /// ビュー（セット詳細）からのアイテム読み出し用アクセサ。
    public func storeForViews() async -> BackupStore { await storeProvider() }

    // MARK: - 反映（コピー＋サイドカー）

    /// 全セットを反映する（コピー・自己修復・サイドカー更新）。
    /// バックアップ完走後・手動「今すぐ反映」・夜間枠から呼ばれる。
    public func syncNow() async {
        // 「提供する」が OFF なら反映しない（受信・バックアップとは独立・ADR-112 追記）。
        guard ShareSettingsKeys.isProvideEnabled() else { return }
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
        defer { isSyncing = false }

        guard let token = try? await tokenProvider.freshAccessToken() else {
            lastError = .notConnected
            BackupLogger.info("Share sync: skipped (no token)")
            return
        }
        lastError = nil

        let store = await storeProvider()
        let copier = makeCopier()
        let shareRoot = ShareSettingsKeys.currentShareRoot()

        for set in await store.allShareSets() {
            // 途中でユーザーが削除操作を始めたら、そこで止める（続きは次回の反映で拾う）。
            if isMutating {
                needsAnotherPass = true
                break
            }
            await sync(set: set, shareRoot: shareRoot, store: store,
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
