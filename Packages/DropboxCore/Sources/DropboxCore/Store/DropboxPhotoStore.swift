#if canImport(UIKit)
import CoreLocation
import CryptoKit
import Foundation
import ImageCacheKit
import MosaicSupport
import Observation
import UIKit

@MainActor
@Observable
public final class DropboxPhotoStore {
    public private(set) var items: [DropboxFileItem] = []
    /// 2-b: 直近反映した items の内容署名（off-main 計算・メインの全比較を避ける）。
    @ObservationIgnored private var lastItemsSignature: Int?
    /// 最後に `items` へ反映したキャッシュの変更リビジョン（`DropboxCacheStore.itemsRevision`）。
    /// 一致していれば全件 fetch を丸ごと省く（ADR-95）。
    @ObservationIgnored private var lastReflectedRevision: Int?
    /// 表示から除外するパス接頭辞（小文字・ADR-112）。同期・キャッシュはそのままに、
    /// items への反映だけをフィルタする（送信側で自分の共有コピーが原本と重複表示されるのを防ぐ）。
    @ObservationIgnored private var excludedPathPrefixes: [String] = []
    /// 実行中の `loadItems()`。起動直後に複数の呼び手が同時に来ても fetch は 1 回に集約する。
    @ObservationIgnored private var loadTask: Task<Int, Never>?
    public private(set) var loadStatus: LoadStatus = .idle
    public private(set) var debugInfo: String = ""
    /// バックグラウンド同期エンジンの現在状態。SettingsView などで表示に使用する。
    public private(set) var syncState: SyncState = .idle {
        didSet { DropboxActivityMonitor.shared.setSync(syncState.activityKind) }
    }
    /// バックアップメタデータ（.mosaic/metadata.json）。ロード前は nil。
    // internal(set): バックアップメタデータの読み込みは別ファイル拡張（+BackupMetadata）が設定する。
    public internal(set) var backupMetadata: DropboxBackupMetadata?

    @ObservationIgnored public let auth: DropboxAuthService
    // 画像/位置の実装は +Images / +Location に分割するため internal（同モジュール内の extension が参照）。
    @ObservationIgnored let cache = DropboxCacheStore()
    @ObservationIgnored let apiClient: DropboxAPIClient
    @ObservationIgnored let thumbnailBatcher: DropboxThumbnailBatcher
    /// キャッシュの持ち主（accountId の指紋）。**永続**させる——アプリを再起動して
    /// 別アカウントへ繋ぎ替えるケースを、メモリ上の変数では検出できないため（レビュー指摘）。
    /// ⚠️ 生の accountId は保存しない。等値比較しかしないので指紋（ハッシュ）で足りる。
    @ObservationIgnored private static let cacheOwnerKey = "dropboxCacheOwnerFingerprint"

    /// キャッシュの持ち主が変わったかの判定（純ロジック・テスト対象）。
    enum CacheOwnerDecision: Equatable {
        /// 未接続など、判断材料が無い（何もしない）。
        case unknown
        /// 持ち主が同じ（キャッシュを温存する）。
        case keep
        /// 記録が無い（初回・旧バージョンからの移行）。指紋を記録するだけ。
        case adopt(String)
        /// 持ち主が違う。**キャッシュを捨ててから**新しい指紋を記録する。
        case clearThenAdopt(String)
    }

    /// - Parameters:
    ///   - stored: 保存されているキャッシュ所有者の指紋（未記録なら nil）。
    ///   - current: 現在接続中のアカウントの指紋（未接続なら nil）。
    static func cacheOwnerDecision(stored: String?, current: String?) -> CacheOwnerDecision {
        // ⚠️ 未接続では**記録を消さない**。消すと次の接続が「初回」に見え、
        // 「切断 → 別アカウントで接続」の切替を検出できなくなる（レビュー指摘）。
        guard let current else { return .unknown }
        guard let stored else { return .adopt(current) }
        return stored == current ? .keep : .clearThenAdopt(current)
    }

    /// accountId → 指紋（保存・比較用）。
    static func accountFingerprint(_ accountId: String) -> String {
        let digest = SHA256.hash(data: Data(accountId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
    /// 同期対象ルートの供給 seam（ADR-44）。アプリ（Composition Root）が
    /// 「選択ソースフォルダ＋バックアップフォルダ」を返すよう結線する。既定は全体。
    @ObservationIgnored public var syncRootsProvider: () -> [String] = { [""] }
    @ObservationIgnored private var syncEngine: DropboxSyncEngine?
    /// アプリ側クラウドお気に入り（cloudPath 集合・UserDefaults 永続）。Dropbox に favorite 概念が
    /// 無いため、cloudPath 単位でアプリが管理する（+Favorites 拡張が読み書き・items へ刻印）。
    @ObservationIgnored var cloudFavoritePaths: Set<String> = DropboxPhotoStore.loadCloudFavorites()

    // キャッシュ→items 反映のスロットリング用。
    @ObservationIgnored private var lastCacheRefresh = Date.distantPast
    @ObservationIgnored private var trailingRefreshTask: Task<Void, Never>?
    private static let cacheRefreshInterval: TimeInterval = 0.4
    /// 初回同期中は delta ページが多数届くため、UI 反映（全件 fetch＋マージ＋グリッド再構築）を
    /// 粗い間隔へ間引いて O(N) 再処理の回数を抑える（完了時に最終反映を即時実行する）。
    private static let initialSyncRefreshInterval: TimeInterval = 5.0

    /// 現在の状態に応じた反映間隔。初回同期中だけ粗くする。
    private var currentRefreshInterval: TimeInterval {
        if case .initialSync = syncState { return Self.initialSyncRefreshInterval }
        return Self.cacheRefreshInterval
    }

    // MARK: - Enums

    public enum LoadStatus: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// バックグラウンド差分同期エンジンの状態。
    public enum SyncState: Equatable {
        case idle
        /// 初回フルスキャン中。`fetched` はスキャン済み画像数。
        case initialSync(fetched: Int)
        /// longpoll 待機中（変更なし→ループ継続）。
        case polling
        /// 変更検知後の差分取得中。
        case fetchingDelta
        case error(String)

        /// アクティビティ計測用の軽量マッピング。
        var activityKind: DropboxActivityMonitor.SyncActivity {
            switch self {
            case .idle:         return .idle
            case .initialSync:  return .initialSync
            case .polling:      return .polling
            case .fetchingDelta: return .fetchingDelta
            case .error:        return .error
            }
        }
    }

    // MARK: - Init

    public init(auth: DropboxAuthService, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.auth = auth
        // E: longpoll は専用セッションで送り、長時間保持の接続を他通信から隔離する。
        let apiClient = DropboxAPIClient(
            httpClient: httpClient, tokenProvider: auth,
            longpollClient: URLSessionHTTPClient(session: .dropboxLongpoll))
        self.apiClient = apiClient
        self.thumbnailBatcher = DropboxThumbnailBatcher(apiClient: apiClient, cache: cache)
    }

    // MARK: - Public API

    /// キャッシュからアイテムをロードして即座に表示する。
    /// メタ情報の取得は `startSync()` が担うため、このメソッドは API を呼ばない。
    public func loadItems() async {
        let accountId = auth.credential?.accountId
        await handleAccountSwitchIfNeeded(currentAccountId: accountId)

        guard let accountId else {
            // credential は存在するが accountId が nil — ここで .idle をセットすると
            // state = .idle → onChange ループになる。state 側の needsSetup チェックに任せる。
            DropboxLogger.error("loadItems() — credential present but accountId is nil; reconnect needed")
            return
        }

        // ⚠️ 同時呼び出しでも fetch は 1 回だけ（ADR-95 追記）。呼び手（MergedPhotoStore /
        //    顔スキャンの候補作り / AutoAlbumAdapters）はいずれも `items.isEmpty` で守っているが、
        //    起動直後は**まだ空**の状態で同時に走るため全員がガードを通り抜け、68,200 行の fetch と
        //    値型生成が多重に走っていた（実機 diagnostics-39: 起動 3 秒の間に 2 回・各 915ms/1062ms）。
        //    リビジョンの札も反映前は更新されないので、札だけでは防げない（check-then-act の競合）。
        if let inFlight = loadTask {
            _ = await inFlight.value
            return
        }
        let task = Task { await reflectCachedItems(accountId: accountId) }
        loadTask = task
        let count = await task.value
        loadTask = nil
        DropboxLogger.info("loadItems() — \(count) items from cache")
    }

    /// キャッシュの内容を `items` に反映する（`loadItems` と `refreshItemsFromCache` の共通処理）。
    /// 2-b: 以前は 67k 件の `cached != items` 全比較を **0.4 秒ごとにメインアクタ**で回していた
    /// （同期中ずっと UI 税）。**署名（Hasher）を off-main で計算**して変化検知し、変わったときだけ
    /// stampFavorites の map＋代入を行う。同一なら @Observable 通知も発火しない（セル churn 防止）。
    @discardableResult
    private func reflectCachedItems(accountId: String) async -> Int {
        // ⚠️ **変わっていなければ fetch すらしない**（ADR-95）。署名比較は「取ってから捨てる」ので、
        //    無変更でも 68,200 行の fetch＋値型生成＋刻印コピーの代金を毎回払っていた。
        //    実機 diagnostics-38 では起動直後の 3 秒間にこれが 2 回走り、`cache.fetchItems` が
        //    993ms / 1165ms、直後にメインが 2.8s / 3.5s ブロックしていた。
        let revision = await cache.currentItemsRevision()
        if revision == lastReflectedRevision, !items.isEmpty {
            updateLoadStatus()
            return items.count
        }
        let raw = await cache.cachedItems(accountId: accountId)   // actor＝off-main フェッチ
        let favPaths = cloudFavoritePaths
        let excluded = excludedPathPrefixes
        // ⚠️ 署名計算**と刻印（68,200 件の map）を同じ detached でまとめて**行う（ADR-88）。
        // 以前は署名だけオフメインで、`stampFavorites(raw)` は @MainActor のここで実行しており、
        // 起動のたびにメインが 2.5〜3.4 秒止まっていた（実測 diag-34・`cache.fetchItems` 直後）。
        // メインは完成した配列を代入するだけにする。
        let (sig, stamped) = await Task.detached(priority: .utility) {
            // 除外フィルタ（ADR-112）も 68k 件の走査なのでオフメインでまとめて行う。
            let visible = excluded.isEmpty ? raw : raw.filter { item in
                let path = item.path.lowercased()
                return !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            return (Self.itemsSignature(visible, favoritePaths: favPaths),
                    favPaths.isEmpty ? visible : visible.map { favPaths.contains($0.path) ? $0.withFavorite(true) : $0 })
        }.value
        lastReflectedRevision = revision
        if sig != lastItemsSignature {
            lastItemsSignature = sig
            items = stamped
        }
        updateLoadStatus()
        updateDebugInfo()
        return raw.count
    }

    /// items の内容署名（count＋各アイテムの Hashable＋お気に入り membership）。off-main で計算する。
    /// プロセス内の比較専用なので Hasher の per-process seed で問題ない。
    nonisolated static func itemsSignature(_ items: [DropboxFileItem], favoritePaths: Set<String>) -> Int {
        var h = Hasher()
        h.combine(items.count)
        for it in items {
            h.combine(it)
            h.combine(favoritePaths.contains(it.path))
        }
        return h.finalize()
    }

    /// 表示中 items 内の 1 アイテムのお気に入り刻印を更新する（+Favorites 拡張が private setter を
    /// 跨がないための橋渡し）。グリッド/情報パネルの★表示へ即反映する。
    func updateDisplayedFavorite(path: String, isFavorite: Bool) {
        guard let idx = items.firstIndex(where: { $0.path == path }) else { return }
        items[idx] = items[idx].withFavorite(isFavorite)
    }

    /// バックグラウンド差分同期ループを開始する。Dropbox 接続時に呼び出す。
    public func startSync() {
        guard case .connected = auth.connectionStatus else { return }
        guard let accountId = auth.credential?.accountId else {
            // ⚠️ accountId がない場合はサイレントに抜けず、エラー状態をセットする。
            // こうしないと state が .idle のまま onChange ループになる（過去に発生）。
            DropboxLogger.error("startSync() — accountId missing; please disconnect and reconnect")
            syncState = .error("Account ID missing. Please reconnect Dropbox in Settings.")
            updateLoadStatus()
            return
        }

        // ⚠️ 実行中の同期タスクをキャンセルしないためのガード。
        // HomeView.onAppear と PhotoSourceContentView.task の両方が startSync() を呼ぶ競合があり、
        // 後者が先に .idle を見て startSync() を二重呼び出しすると既存タスクが stop() でキャンセルされる。
        // .idle / .error の場合のみ新規起動を許可する。
        switch syncState {
        case .initialSync, .polling, .fetchingDelta:
            DropboxLogger.info("DropboxPhotoStore: startSync() skipped — sync already active (\(syncState))")
            return
        case .idle, .error:
            break
        }

        // syncState を即座に .initialSync に変更して、
        // 直後に呼ばれる 2 回目の startSync() が .idle を見て再起動しないようにする。
        syncState = .initialSync(fetched: 0)
        updateLoadStatus()

        // ADR-44: 同期対象ルート（選択フォルダ＋バックアップフォルダ・正規化/包含畳み込み済み）。
        // 前回と変わっていたら、カーソルはパスに紐づくためキャッシュを破棄して作り直す
        //（スコープ外アイテムの残留と cursor 不整合を防ぐ）。
        let roots = DropboxSourceSettings.normalizedRoots(syncRootsProvider())
        let rootsMarkerKey = "dropboxSyncRoots:\(accountId)"
        let rootsMarker = roots.joined(separator: "\u{1F}")
        if let stored = UserDefaults.standard.string(forKey: rootsMarkerKey), stored != rootsMarker {
            DropboxLogger.info("startSync() — sync roots changed; resetting cache for rescan")
            Task {
                await cache.clearAll(accountId: accountId)
                items = []; lastItemsSignature = nil
                UserDefaults.standard.set(rootsMarker, forKey: rootsMarkerKey)
                syncEngine?.start(accountId: accountId, roots: roots)
            }
            // エンジン生成は下で済ませてから上の Task が start する（既存エンジンがあればそのまま）。
        } else {
            UserDefaults.standard.set(rootsMarker, forKey: rootsMarkerKey)
        }

        if syncEngine == nil {
            syncEngine = DropboxSyncEngine(
                apiClient: apiClient,
                cache: cache,
                onCacheUpdated: { [weak self] changedLower in
                    guard let self else { return }
                    // 変更が**除外パス配下だけ**なら items 反映をスキップする（ADR-112 追記・
                    // diagnostics-52: 自分の共有コピーが 1 秒ごとに longpoll 変更を発火し、
                    // そのたび 69k 件の全件フェッチ（1.2s）が走り続けてメインを飢餓させた。
                    // 除外パスは表示に現れないので反映する意味がない）。
                    if !changedLower.isEmpty, !self.excludedPathPrefixes.isEmpty,
                       changedLower.allSatisfy({ path in
                           self.excludedPathPrefixes.contains {
                               path == $0 || path.hasPrefix($0 + "/")
                           }
                       }) {
                        return
                    }
                    // 初回同期はページごとに頻発するため、16k 件の再フェッチ/再代入を
                    // スロットリング（先頭即時＋以降は ~0.4s 間引き）してメイン負荷を抑える。
                    self.scheduleCacheRefresh()
                },
                onStateChanged: { [weak self] newState in
                    guard let self else { return }
                    // キャンセルされた古いタスクが .idle を返しても、
                    // 新しい startSync() がすでに設定した active な syncState を上書きしない。
                    if case .idle = newState {
                        switch self.syncState {
                        case .initialSync, .polling, .fetchingDelta:
                            return
                        default: break
                        }
                    }
                    let wasInitialSync: Bool = { if case .initialSync = self.syncState { return true } else { return false } }()
                    self.syncState = newState
                    self.updateLoadStatus()
                    self.updateDebugInfo()
                    // 初回同期が終わったら、間引いていた分の最終反映を即時に行う。
                    let stillInitialSync: Bool = { if case .initialSync = newState { return true } else { return false } }()
                    if wasInitialSync, !stillInitialSync { self.forceCacheRefreshSoon() }
                }
            )
        }

        // ルート変更時は上の Task（クリア後）が start する。通常はここで即 start。
        let storedMarker = UserDefaults.standard.string(forKey: "dropboxSyncRoots:\(accountId)")
        if storedMarker == rootsMarker {
            syncEngine?.start(accountId: accountId, roots: roots)
        }
        DropboxLogger.info("DropboxPhotoStore: startSync() accountId=\(accountId) roots=\(roots.map { $0.isEmpty ? "/" : $0 })")
    }

    /// キャッシュ→items 反映をスロットリングして実行する。
    /// 直近反映から `cacheRefreshInterval` 未満の連続呼び出しは1回に集約する。
    private func scheduleCacheRefresh() {
        guard trailingRefreshTask == nil else { return }   // 既に保留中なら集約
        let elapsed = Date().timeIntervalSince(lastCacheRefresh)
        let delay = max(0, currentRefreshInterval - elapsed)
        trailingRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.trailingRefreshTask = nil
            self.lastCacheRefresh = Date()
            await self.refreshItemsFromCache()
        }
    }

    /// 保留中の間引きを取り消し、最終反映を即時にスケジュールする（初回同期完了時など）。
    private func forceCacheRefreshSoon() {
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        lastCacheRefresh = .distantPast
        scheduleCacheRefresh()
    }

    /// キャッシュから items を取得して反映する（内容が変わったときのみ再代入・2-b の署名比較）。
    private func refreshItemsFromCache() async {
        guard let accountId = auth.credential?.accountId else { return }
        await reflectCachedItems(accountId: accountId)
    }

    /// 表示から除外するパス接頭辞を設定する（ADR-112・送信側の自分の共有ルート等）。
    /// 変更時は次回反映で必ず再計算されるようにし、即時の反映も予約する。
    public func setExcludedPathPrefixes(_ prefixes: [String]) {
        let normalized = prefixes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "/" }
        guard normalized != excludedPathPrefixes else { return }
        excludedPathPrefixes = normalized
        lastReflectedRevision = nil
        lastItemsSignature = nil
        forceCacheRefreshSoon()
    }

    /// バックグラウンド同期ループを停止する。
    public func stopSync() {
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        syncEngine?.stop()
        syncState = .idle
        DropboxLogger.info("DropboxPhotoStore: stopSync()")
    }

    /// 同期を停止し、表示状態をリセットする。切断・アカウント切替時に呼び出す。
    public func reset() {
        stopSync()
        resetLoad()
    }

    /// キャッシュ（メタデータ＋バイナリ）を全消去して再同期する。デバッグの「Clear Cache」用。
    /// actor キャッシュ経由で消去するため、別コンテナとの不整合や「消去後に再同期されず空のまま」を防ぐ。
    public func clearCache() async {
        stopSync()  // syncState=.idle、保留中のリフレッシュも解除
        loadTask?.cancel()
        loadTask = nil
        if let accountId = auth.credential?.accountId {
            await cache.clearAll(accountId: accountId)  // cursor 含むメタ＋バイナリを消去
        }
        resetLoad()   // items=[], loadStatus=.idle
        startSync()   // cursor 消去済み → initialSync で再取得（接続済みのときのみ実行）
    }

    func resetLoad() {
        // ⚠️ 進行中の読み込みを**必ず止める**。止めないと、リセット後に古いスナップショットが
        // items へ再代入され、切断したはずの一覧が戻る（レビュー指摘）。
        loadTask?.cancel()
        loadTask = nil
        loadStatus = .idle
        items = []; lastItemsSignature = nil
        debugInfo = ""
        backupMetadata = nil
        // ⚠️ キャッシュの持ち主（永続の指紋）は消さない。消すと次に別アカウントで接続したとき
        // 「初めて」に見えてしまい、旧アカウントのキャッシュを新アカウントの写真として読む。
        DropboxLogger.info("resetLoad() — state cleared")
    }

    /// 読み込み対象フォルダの変更を適用する（ADR-44・設定 UI から呼ぶ）。
    /// 同期を止めて再スタートする。ルートが変わっていれば startSync 内の
    /// マーカー検知がキャッシュを破棄して初回同期をやり直す。
    public func applySourceFolderChange() {
        syncEngine?.stop()
        syncState = .idle
        startSync()
    }

    // MARK: - Cache limit configuration

    /// Updates the running cache byte limits and evicts if the new limit is tighter.
    /// Call this when the user changes limit settings so the change takes effect immediately.
    public func applyCacheLimits(thumbnailMB: Int, fullImageMB: Int) async {
        await cache.setThumbnailByteLimit(thumbnailMB * 1_024 * 1_024)
        await cache.setFullImageByteLimit(fullImageMB * 1_024 * 1_024)
    }

    /// サムネイルの同時バッチ取得数を設定で変更する（常識的範囲にクランプ）。
    public func applyThumbnailConcurrency(_ value: Int) {
        thumbnailBatcher.setMaxConcurrentRequests(value)
    }

    /// キャッシュ使用状況のスナップショット（設定の Cache Status 表示用）。
    public func cacheUsage() async -> DropboxCacheUsage {
        await cache.usageSnapshot()
    }

    /// デバッグ画面用のキャッシュスナップショット（件数・使用量・直近一覧）。
    /// 別コンテナを開かず動作中のキャッシュアクターから読む（同一ストアの二重オープン回避）。
    public func cacheDebugSnapshot() async -> DropboxCacheDebugSnapshot {
        await cache.debugSnapshot(accountId: auth.credential?.accountId ?? "")
    }

    /// 同期ループを停止して再開する（設定の Debug「Force re-sync」用）。
    /// キャッシュ済みカーソルがあれば polling を、無ければ initialSync を再起動する。
    public func forceResync() {
        stopSync()
        startSync()
    }

    // 画像取得（thumbnail/fullImage/cover/originalData/prefetch）は DropboxPhotoStore+Images.swift、
    // 位置解決（location/cachedLocation）は DropboxPhotoStore+Location.swift に分割。

    // MARK: - Private helpers

    /// キャッシュの持ち主が変わっていないかを確かめ、変わっていたら**キャッシュを捨てる**。
    ///
    /// ⚠️ 以前はメモリ上の `lastKnownAccountId` で判定し、切断時にそれを nil へ戻していた。
    /// そのため「切断 → 別アカウントで接続」でも「再起動を挟む切替」でも前回値が nil になり、
    /// **旧アカウントのキャッシュを新アカウントの写真として表示**し得た（レビュー指摘）。
    /// 判定は永続化した指紋で行う。同じアカウントへ繋ぎ直したときはキャッシュを温存する。
    private func handleAccountSwitchIfNeeded(currentAccountId: String?) async {
        // 未接続（accountId なし）では何も判断しない。持ち主の記録も消さない
        // ——消すと次の接続で「初めて」に見え、切替を検出できなくなる。
        let defaults = UserDefaults.standard
        let decision = Self.cacheOwnerDecision(
            stored: defaults.string(forKey: Self.cacheOwnerKey),
            current: currentAccountId.map(Self.accountFingerprint))
        switch decision {
        case .unknown, .keep:
            return
        case .adopt(let fingerprint):
            defaults.set(fingerprint, forKey: Self.cacheOwnerKey)
        case .clearThenAdopt(let fingerprint):
            DropboxLogger.info("account switched (cache owner differs) — clearing cache")
            // 進行中の読み込みを止めてから消す。止めないと、消した後に**旧一覧が再代入**され得る。
            loadTask?.cancel()
            loadTask = nil
            if let currentAccountId { await cache.clearAll(accountId: currentAccountId) }
            items = []; lastItemsSignature = nil
            backupMetadata = nil
            defaults.set(fingerprint, forKey: Self.cacheOwnerKey)
        }
    }

    private func updateLoadStatus() {
        if items.isEmpty {
            switch syncState {
            // ⚠️ .idle のまま返すと PhotoSourceContentView の onChange(.idle) が
            // start() を繰り返し呼ぶ無限ループになる。接続済みで呼ばれるため .loading を返す。
            case .idle, .initialSync, .fetchingDelta:
                loadStatus = .loading
            // 初回同期完了（polling 状態）はアイテムが空でも「ロード完了」扱いにする。
            // state プロパティが items.isEmpty を見て .empty を返す。
            case .polling:
                loadStatus = .loaded
            case .error(let msg):
                loadStatus = .failed(msg)
            }
        } else {
            loadStatus = .loaded
        }
    }

    private func updateDebugInfo() {
        let syncSummary: String
        switch syncState {
        case .idle:                     syncSummary = "idle"
        case .initialSync(let n):       syncSummary = "initial (\(n))"
        case .polling:                  syncSummary = "watching"
        case .fetchingDelta:            syncSummary = "updating"
        case .error:                    syncSummary = "error"
        }
        debugInfo = "images: \(items.count) · sync: \(syncSummary)"
    }
}
#endif
