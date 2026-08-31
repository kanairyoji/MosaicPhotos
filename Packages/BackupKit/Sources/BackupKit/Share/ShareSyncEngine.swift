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

    // ⚠️ `internal(set)`：反映（`+Sync`）が同じ型の別ファイルにあるため、`private(set)` だと
    // 書けない。外部（アプリ）に対しては従来どおり読み取り専用のまま。
    public internal(set) var sets: [SetSummary] = []
    public internal(set) var isSyncing = false
    /// 走行中に来た反映要求（終わったら 1 回だけ再走する）。
    @ObservationIgnored var needsAnotherPass = false
    /// 削除系（セット削除・単枚解除）の実行中フラグ。反映と**相互排他**にする。
    ///
    /// ⚠️ 排他しないと「削除 → 走行中の反映が続きのチャンクをコピー」で、消したはずの
    /// 共有フォルダが写真つきで復活し、記録が無いので二度と掃除されない（レビュー指摘）。
    @ObservationIgnored var isMutating = false
    public internal(set) var lastSyncAt: Date?
    public internal(set) var lastError: SyncError?

    /// 反映の失敗種別。**表示側で翻訳する**ため文言をここに持たない
    /// （規約: 動的 String は verbatim＝未翻訳になる）。
    public enum SyncError: Equatable, Sendable {
        case notConnected
        case folderPrepareFailed
        case folderCheckFailed
        case folderRemoveFailed
        case invalidFolderName
        /// 反映を止められず、変更操作を安全に行えなかった（再試行で解消する）。
        case syncBusy
    }

    @ObservationIgnored let tokenProvider: AccessTokenProvider
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored let storeProvider: @MainActor () async -> BackupStore
    /// 設定の読み出し先。既定は `.standard`、テストは専用スイートを渡して独立させる。
    @ObservationIgnored let defaults: UserDefaults

    /// 現在の Dropbox アカウントの指紋。墓標をアカウントごとに分けるために使う
    /// （⚠️ 猶予時間内にアカウントを切り替えると、**別アカウントの同名フォルダ**を
    /// 消しに行く・レビュー指摘）。未注入なら nil＝「持ち主不明」として分離される。
    @ObservationIgnored public var accountFingerprint: @MainActor () -> String? = { nil }
    /// 解析サイドカーの供給元（未設定なら写真のみ共有）。
    @ObservationIgnored public weak var analysisSource: ShareAnalysisSource?
    /// 作成元の現在メンバー解決（未設定なら「今の内容に更新」を出さない）。
    @ObservationIgnored public weak var sourceResolver: ShareSourceResolver?
    /// 非同期ジョブのポーリング設定（テストで短縮する。本番は既定値）。
    @ObservationIgnored var pollIntervalNs: UInt64?
    @ObservationIgnored var maxPollAttempts: Int?

    /// 生成した copier に、テスト用のポーリング設定を反映する。
    func makeCopier() -> DropboxShareCopier {
        var copier = DropboxShareCopier(httpClient: httpClient)
        if let pollIntervalNs { copier.pollIntervalNs = pollIntervalNs }
        if let maxPollAttempts { copier.maxPollAttempts = maxPollAttempts }
        return copier
    }

    /// 1 回の copy_batch に載せる最大エントリ数。
    static let copyChunkSize = 100
    /// 1 回の反映で投げるコピー / 削除の上限（diagnostics-55）。暴走の後始末は数千件に
    /// なり得るが、一度に流すと API レート制限を誘発し、失敗→再試行でさらに負荷が増える。
    /// 残りは次回の反映で続きから片付ける（計画は毎回実在照合するので取りこぼさない）。
    static let maxCopiesPerRun = 500
    static let maxDeletesPerRun = 500

    public init(tokenProvider: AccessTokenProvider,
                storeProvider: @escaping @MainActor () async -> BackupStore,
                httpClient: HTTPClient = URLSessionHTTPClient(),
                defaults: UserDefaults = .standard) {
        self.tokenProvider = tokenProvider
        self.storeProvider = storeProvider
        self.httpClient = httpClient
        self.defaults = defaults
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
                // ⚠️ 種類は `sourceKey` が無くても**フォルダ名**が知っている（`Album-` / `Person-` /
                // `People-`）。人物由来のセットは clusterID が当てにならなくなると sourceKey を
                // 外すので、フォルダ名を見ないと「種類不明」に落ちて名前だけの照合になる
                //（実フィードバック 8/31: 同名の AI アルバムが人物の共有に結び付いた）。
                let existingKind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
                    ?? ShareNaming.kind(fromFolderName: set.folderName)
                // 本当に種類が分からないセット（接頭辞なしの旧セット）だけ名前一致で再利用する。
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

        // フォルダ名には種類の接頭辞を付ける（`People-◯◯` / `Album-◯◯`）。
        // Dropbox 上で何のアルバムか分かり、種類違いの同名でも衝突しない。
        let folderName = ShareNaming.folderName(name, kind: requestedKind,
                                                existing: allSets.map(\.folderName))
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
    ///
    /// ⚠️ 削除系（`deleteSet` / `removeItems`）と**同じ排他区間**に入れること。反映は先に読んだ
    /// 計画でコピーするため、排他なしで除外すると「記録を消した後に旧計画がコピー」して
    /// 孤児ファイルが残る（レビュー指摘）。
    @discardableResult
    public func updateSetMembers(setID: UUID, refKeys: [String], sourceKey: String? = nil,
                                 store: BackupStore? = nil) async -> (added: Int, removed: Int) {
        // 呼び出し元（createSet の再利用経路）が既に排他を取っている場合は二重に取らない。
        let ownsExclusion = !isMutating
        if ownsExclusion {
            isMutating = true
            guard await waitForSyncToPause() else {
                isMutating = false
                lastError = .syncBusy
                return (0, 0)
            }
        }
        defer { if ownsExclusion { isMutating = false } }

        let resolvedStore: BackupStore
        if let store { resolvedStore = store } else { resolvedStore = await storeProvider() }
        let store = resolvedStore
        let wanted = Set(refKeys)
        let current = await store.shareItems(setID: setID)
        let obsolete = current.filter { !wanted.contains($0.refKey) }

        var removed = 0
        if !obsolete.isEmpty {
            // 共有フォルダ側の実ファイルも消す（記録だけ消すと孤児ファイルが残る）。
            // ⚠️ **消せたときだけ記録を消す**。失敗しても記録を消すと、以後その写真を
            // 自分の持ち物として認識できず孤児が永久に残る（レビュー指摘）。
            let paths = obsolete.compactMap(\.sharedPath)
            var ok = true
            if !paths.isEmpty {
                if let token = try? await tokenProvider.freshAccessToken() {
                    ok = await makeCopier().deleteBatch(paths: paths, token: token)
                    if !ok { lastError = .folderRemoveFailed }
                } else {
                    ok = false
                    lastError = .notConnected
                }
            }
            // 未コピー分も、発行済みのサーバー側ジョブで後から現れ得る（上と同じ理由）。
            await addFileTombstones(for: obsolete.filter { $0.sharedPath == nil }, setID: setID,
                                    store: store)
            // まだコピーされていない分は共有側に何も無いので、失敗時もそのまま外してよい。
            let dropped = ok ? obsolete : obsolete.filter { $0.sharedPath == nil }
            if !dropped.isEmpty {
                await store.removeShareItems(setID: setID, refKeys: dropped.map(\.refKey))
            }
            removed = dropped.count
        }
        let added = await store.addShareItems(setID: setID, refKeys: refKeys)
        if let sourceKey { await store.setShareSourceKey(setID: setID, sourceKey: sourceKey) }
        return (added, removed)
    }

    /// 反映をバックグラウンドで開始する（進捗はハブの isSyncing / セット状態で見える）。
    private func scheduleSync() {
        Task { await syncNow() }
    }

    /// 進行中の反映（キャンセル可能にするため保持する）。`syncNow` が張り替える。
    @ObservationIgnored var syncTask: Task<Void, Never>?

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

    /// この作成元（人物 / グループ / アルバム）を今クラウド共有しているか——していれば
    /// そのセット ID。共有を**停止**するメニューを出すかの判定に使う。
    ///
    /// 照合の規則は `createSet` の再利用と揃える: 作成元キーの完全一致 → **同じ種類**かつ同名。
    /// （グループを解除して同じ名前で作り直すと ID が変わるため名前でも拾う。ただし
    /// AI アルバムとピープルグループの同名を取り違えないよう種類で絞る。）
    /// `sets` は数個〜数十個なのでビューから同期的に呼んでよい。
    public func sharedSetID(sourceKey: String, name: String) -> UUID? {
        if let match = sets.first(where: { $0.sourceKey != nil && $0.sourceKey == sourceKey }) {
            return match.id
        }
        let requestedKind = ShareSourceKey(sourceKey)?.kind
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sets.first { set in
            guard set.name == trimmed else { return false }
            // 種類は sourceKey が無ければフォルダ名から復元する（`createSet` と同じ規則）。
            let kind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
                ?? ShareNaming.kind(fromFolderName: set.folderName)
            return kind == nil || kind == requestedKind
        }?.id
    }

    /// **人物由来**の共有セットから作成元キーを外す。
    ///
    /// ⚠️ `person-<clusterID>` の clusterID は顔の全消去で振り直される（永続 ID ではない）。
    /// 参照を残したままだと、同じ番号が**別人**に割り当たったとき、次の反映でその人の写真を
    /// 家族フォルダへ追加してしまう（レビュー指摘）。番号が当てにならなくなった時点で外す。
    /// セットと共有済みの写真はそのまま残る（同じ名前で共有し直せば再び結び付く）。
    /// - Returns: 外したセット数。
    @discardableResult
    public func detachPersonSources() async -> Int {
        let store = await storeProvider()
        var detached = 0
        for set in await store.allShareSets() {
            guard let key = set.sourceKey, ShareSourceKey(key)?.kind == .person else { continue }
            await store.clearShareSourceKey(setID: set.id)
            detached += 1
        }
        if detached > 0 {
            BackupLogger.info("Share: detached \(detached) person set(s) — cluster IDs were reset")
            await refresh()
        }
        return detached
    }

    /// クラウド共有を停止する（＝共有フォルダごと削除する）。`deleteSet` の別名で、
    /// 呼び出し側の意図（設定画面の「セット削除」ではなく、共有元からの「停止」）を残す。
    /// 正本（端末写真・バックアップ）には触れない。
    @discardableResult
    public func stopSharing(setID: UUID) async -> Bool {
        await deleteSet(id: setID)
    }

    /// セットを削除する（共有フォルダごと）。リモート削除に失敗したら記録は残す（再試行可能）。
    public func deleteSet(id: UUID) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        // 反映を止められないまま消すと、進行中のコピーがフォルダを復活させて
        // 「記録は消えたのにクラウドには残る」になる。止まらないなら何もしない。
        guard await waitForSyncToPause() else {
            lastError = .syncBusy
            return false
        }
        guard let token = try? await tokenProvider.freshAccessToken() else {
            lastError = .notConnected
            return false
        }
        let store = await storeProvider()
        guard let set = await store.allShareSets().first(where: { $0.id == id }) else { return true }
        // ⚠️ 不正なフォルダ名（空・区切り・親参照）では**絶対に削除しない**。
        // 空名を許すと共有ルートごと消える。記録だけ消して手動対応に委ねる。
        guard let folder = SharePlanning.setFolderPath(
                shareRoot: ShareSettingsKeys.currentShareRoot(defaults), folderName: set.folderName,
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
        // 墓標を残す。進行中だったコピーが後から完走してフォルダを復活させても、
        // 次以降の反映が消し直せるようにする（クライアント側のキャンセルでは止まらない）。
        let account = accountFingerprint()
        var tombstones = ShareSettingsKeys.deletedFolderTombstones(account: account, defaults)
        tombstones[folder] = Date()
        ShareSettingsKeys.setDeletedFolderTombstones(tombstones, account: account, defaults)
        BackupLogger.info("Share: deleted set '\(set.folderName)'")
        await refresh()
        return true
    }

    /// 写真をセットから外す（コピー済みなら共有側ファイルも削除）。
    ///
    /// ⚠️ **共有側を消せたときだけ記録を消す**。以前は削除の成否を無視して記録を消していたため、
    /// 失敗すると以後その写真を自分の持ち物として認識できず、共有先に孤児ファイルが
    /// 永久に残っていた（レビュー指摘）。失敗時は記録を残して再試行できる状態に保つ。
    @discardableResult
    public func removeItems(setID: UUID, refKeys: [String]) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        guard await waitForSyncToPause() else {
            lastError = .syncBusy
            return false
        }
        let store = await storeProvider()
        let items = await store.shareItems(setID: setID)
        let targets = items.filter { refKeys.contains($0.refKey) }
        // ⚠️ 「まだコピーされていない」は**この瞬間の記録**でしかない。反映を止めても
        // Dropbox 側で発行済みの copy_batch は完走するため、記録を消した後にファイルが
        // 現れ得る（レビュー指摘）。予定されていたコピー先に**ファイル墓標**を置いて、
        // 後から現れたら次の反映で消す。
        await addFileTombstones(for: targets.filter { $0.sharedPath == nil }, setID: setID,
                                store: store)
        let removable = Set(targets.filter { $0.sharedPath == nil }.map(\.refKey))
        let remotePaths = targets.compactMap(\.sharedPath)
        var ok = true
        if !remotePaths.isEmpty {
            if let token = try? await tokenProvider.freshAccessToken() {
                ok = await makeCopier().deleteBatch(paths: remotePaths, token: token)
                if !ok { lastError = .folderRemoveFailed }
            } else {
                ok = false
                lastError = .notConnected
            }
        }
        let toRemove = ok ? refKeys : refKeys.filter { removable.contains($0) }
        if !toRemove.isEmpty { await store.removeShareItems(setID: setID, refKeys: toRemove) }
        await refresh()
        scheduleSync()   // サイドカーから外した分を反映
        return ok
    }

    /// 反映を止めてから変更操作へ進む。**止まったかどうかを返す**。
    ///
    /// ⚠️ 以前は 3 秒待って*無条件に*先へ進んでいた。しかしコピーのポーリングは最長 4 分あり、
    /// `sync(set:)` は途中で `isMutating` を見直さない。結果、セット削除の後に進行中のコピーが
    /// 完走して**共有フォルダだけ復活し、ローカル記録は消えている**状態になり得た（レビュー指摘）。
    /// → (1) 反映 Task を**キャンセル**して終了を待つ、(2) それでも止まらなければ
    /// **変更操作を中止**する（記録とクラウドの食い違いを作るくらいなら、やらない方がよい）。
    private func waitForSyncToPause(timeoutMs: Int = 8000) async -> Bool {
        guard isSyncing else { return true }
        syncTask?.cancel()
        var waited = 0
        while isSyncing, waited < timeoutMs {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 100
        }
        if isSyncing {
            BackupLogger.error("Share: sync did not stop in time — aborting the mutation")
            return false
        }
        return true
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
}
