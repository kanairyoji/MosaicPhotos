#if canImport(UIKit)
import CoreLocation
import Foundation
import ImageCacheKit
import MosaicSupport
import Observation
import UIKit

@MainActor
@Observable
public final class DropboxPhotoStore {
    public private(set) var items: [DropboxFileItem] = []
    public private(set) var loadStatus: LoadStatus = .idle
    public private(set) var debugInfo: String = ""
    /// バックグラウンド同期エンジンの現在状態。SettingsView などで表示に使用する。
    public private(set) var syncState: SyncState = .idle {
        didSet { DropboxActivityMonitor.shared.setSync(syncState.activityKind) }
    }
    /// バックアップメタデータ（.mosaic/metadata.json）。ロード前は nil。
    public private(set) var backupMetadata: DropboxBackupMetadata?

    @ObservationIgnored public let auth: DropboxAuthService
    // 画像/位置の実装は +Images / +Location に分割するため internal（同モジュール内の extension が参照）。
    @ObservationIgnored let cache = DropboxCacheStore()
    @ObservationIgnored let apiClient: DropboxAPIClient
    @ObservationIgnored let thumbnailBatcher: DropboxThumbnailBatcher
    @ObservationIgnored private var lastKnownAccountId: String?
    /// 同期対象ルートの供給 seam（ADR-44）。アプリ（Composition Root）が
    /// 「選択ソースフォルダ＋バックアップフォルダ」を返すよう結線する。既定は全体。
    @ObservationIgnored public var syncRootsProvider: () -> [String] = { [""] }
    @ObservationIgnored private var syncEngine: DropboxSyncEngine?

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

        let cached = await cache.cachedItems(accountId: accountId)
        // 内容が同一なら再代入しない。@Observable 通知が発火して
        // PhotoGridView が再評価され、サムネイル取得中のセルが churn するのを防ぐ。
        if cached != items {
            items = cached
        }
        updateLoadStatus()
        updateDebugInfo()
        DropboxLogger.info("loadItems() — \(cached.count) items from cache")
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
                items = []
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
                onCacheUpdated: { [weak self] in
                    // 初回同期はページごとに頻発するため、16k 件の再フェッチ/再代入を
                    // スロットリング（先頭即時＋以降は ~0.4s 間引き）してメイン負荷を抑える。
                    self?.scheduleCacheRefresh()
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

    /// キャッシュから items を取得して反映する（内容が変わったときのみ再代入）。
    private func refreshItemsFromCache() async {
        guard let accountId = auth.credential?.accountId else { return }
        let cached = await cache.cachedItems(accountId: accountId)
        if cached != items {
            items = cached
        }
        updateLoadStatus()
        updateDebugInfo()
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
        if let accountId = auth.credential?.accountId {
            await cache.clearAll(accountId: accountId)  // cursor 含むメタ＋バイナリを消去
        }
        resetLoad()   // items=[], loadStatus=.idle
        startSync()   // cursor 消去済み → initialSync で再取得（接続済みのときのみ実行）
    }

    func resetLoad() {
        loadStatus = .idle
        items = []
        debugInfo = ""
        lastKnownAccountId = nil
        backupMetadata = nil
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

    // MARK: - Backup metadata

    /// バックアップメタデータを読み込んで `backupMetadata` に保持する。
    /// v1（凍結された `.mosaic/metadata.json`）をベースに、v2（`.mosaic/catalog.json`＋
    /// 月別シャード）を**上書きマージ**する（ADR-38）。どちらも無ければ nil のまま。
    /// バックアップ完了後、または起動時に呼び出す。
    public func loadBackupMetadata(from folderPath: String) async {
        await loadBackupMetadata(from: [folderPath])
    }

    /// 複数ルート版（ADR-41）。端末フォルダ導入後は「バックアップルート（旧・フラット時代の
    /// 既存分）＋この端末のフォルダ」の 2 箇所を統合して読む。
    ///
    /// A2 パフォーマンス: 旧実装は毎起動で v1 metadata.json（最大 15〜25MB）＋全シャードを
    /// **逐次**ダウンロードし **MainActor 上で**デコードしていた。現実装は
    /// (1) 各 JSON の **rev**（Dropbox の版数）を get_metadata で確認し、前回と同じなら
    ///     ローカルキャッシュ（Caches/DropboxKit/backup-metadata/）を使う（本文 DL なし）
    /// (2) 変わった分だけダウンロード（v1・シャードは**並列**）
    /// (3) デコード・マージは **Task.detached（オフメイン）** で行い、完成値だけをメインへ
    public func loadBackupMetadata(from folderPaths: [String]) async {
        // 対象 JSON のパス一覧（各ルートの v1 ＋ カタログ経由のシャード）。
        // カタログ自体は小さいので fetchCachedJSON で取得しつつシャード一覧を得る。
        var jsonPaths: [String] = []
        for folderPath in folderPaths {
            jsonPaths.append(folderPath + DropboxInternalConstants.backupMetadataSuffix)
            let catalogPath = folderPath + BackupMetadataV2.catalogSuffix
            if let catalog: BackupCatalog = await fetchCachedJSON(path: catalogPath) {
                jsonPaths.append(contentsOf: catalog.shards.map {
                    folderPath + BackupMetadataV2.shardSuffix($0)
                })
            }
        }
        // v1・シャードを並列取得（rev 一致ならキャッシュ＝通信は get_metadata 1 往復のみ）。
        let parts: [DropboxBackupMetadata] = await withTaskGroup(
            of: DropboxBackupMetadata?.self, returning: [DropboxBackupMetadata].self
        ) { group in
            for path in jsonPaths {
                group.addTask { [weak self] in
                    await self?.fetchCachedJSON(path: path)
                }
            }
            var out: [DropboxBackupMetadata] = []
            for await part in group {
                if let part { out.append(part) }
            }
            return out
        }
        guard !parts.isEmpty else {
            DropboxLogger.info("loadBackupMetadata() — no metadata found (\(folderPaths.joined(separator: ", ")))")
            return
        }
        // マージはオフメインで（数万エントリの辞書結合をメインに載せない）。
        // エントリのキーは「実際に保存されたパス」なので、ファイル間で重複するキーは
        // 同一写真の同一エントリ＝マージ順序に意味はない。
        let merged = await Task.detached(priority: .userInitiated) {
            var out = DropboxBackupMetadata()
            for part in parts { out = out.merging(part.entries) }
            return out
        }.value
        backupMetadata = merged
        DropboxLogger.info("loadBackupMetadata() — loaded \(merged.entries.count) entries (\(parts.count) file(s), rev-cached)")
    }

    /// rev ベースのローカルキャッシュつき JSON 取得（A2）。
    /// 1) `files/get_metadata` で rev を確認（1 RPC・数百バイト）
    /// 2) 前回 rev と一致 → ローカルキャッシュから**オフメインで**デコード（本文 DL なし）
    /// 3) 不一致/初回 → ダウンロードしてキャッシュ保存＋rev 記録
    /// ファイルが存在しない・エラー時は nil。
    private struct MetaRevBody: Encodable { let path: String }
    private struct MetaRevResponse: Decodable { let rev: String? }
    private struct MetaDownloadArg: Encodable { let path: String }

    private func fetchCachedJSON<T: Decodable & Sendable>(path: String) async -> T? {
        let cacheDir = Self.metadataCacheDirectory
        let cacheFile = cacheDir.appendingPathComponent(
            path.lowercased().data(using: .utf8)!.base64EncodedString()
                .replacingOccurrences(of: "/", with: "_") + ".json")
        let revKey = "backupMetaRev:" + path.lowercased()

        // 1) リモートの rev を確認（取得できない＝ファイル自体が無い/通信不可）。
        var remoteRev: String?
        if let body = try? JSONEncoder().encode(MetaRevBody(path: path)),
           let data = try? await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL, jsonBody: body),
           let meta = try? JSONDecoder().decode(MetaRevResponse.self, from: data) {
            remoteRev = meta.rev
        }
        guard let remoteRev else { return nil }

        // 2) rev 一致ならキャッシュから（オフメインでデコード）。
        if UserDefaults.standard.string(forKey: revKey) == remoteRev,
           let cached = await Task.detached(priority: .userInitiated, operation: {
               guard let data = try? Data(contentsOf: cacheFile) else { return nil as T? }
               return try? JSONDecoder().decode(T.self, from: data)
           }).value {
            return cached
        }

        // 3) ダウンロード → オフメインでデコード → キャッシュ保存。
        guard let argString = encodeDropboxAPIArg(MetaDownloadArg(path: path)),
              let data = try? await apiClient.contentDownload(
                  url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated, operation: {
            try? JSONDecoder().decode(T.self, from: data)
        }).value
        guard let decoded else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFile)
        UserDefaults.standard.set(remoteRev, forKey: revKey)
        return decoded
    }

    /// メタデータキャッシュの置き場（Caches 配下＝OS が容量逼迫時に破棄してよい）。
    private static var metadataCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxKit/backup-metadata", isDirectory: true)
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

    private func handleAccountSwitchIfNeeded(currentAccountId: String?) async {
        defer { lastKnownAccountId = currentAccountId }
        guard let previous = lastKnownAccountId, previous != currentAccountId else { return }
        DropboxLogger.info("account switched \(previous) → \(currentAccountId ?? "nil") — clearing cache")
        await cache.clearAll(accountId: previous)
        items = []
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
