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
        /// 反映を止められず、変更操作を安全に行えなかった（再試行で解消する）。
        case syncBusy
    }

    @ObservationIgnored private let tokenProvider: AccessTokenProvider
    @ObservationIgnored private let httpClient: HTTPClient
    @ObservationIgnored private let storeProvider: @MainActor () async -> BackupStore
    /// 設定の読み出し先。既定は `.standard`、テストは専用スイートを渡して独立させる。
    @ObservationIgnored private let defaults: UserDefaults

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
    @ObservationIgnored private var syncTask: Task<Void, Never>?

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
            let kind = set.sourceKey.flatMap(ShareSourceKey.init)?.kind
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

    // MARK: - 反映（コピー＋サイドカー）

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
            case .failed:
                // 移動先が既にある / 通信断。次回に持ち越す（他の候補も同じ理由で失敗する）。
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
    private func addFileTombstones(for items: [ShareItemLite], setID: UUID,
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
