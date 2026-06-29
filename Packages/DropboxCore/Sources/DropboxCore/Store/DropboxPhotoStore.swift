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
    @ObservationIgnored private let cache = DropboxCacheStore()
    @ObservationIgnored private let apiClient: DropboxAPIClient
    @ObservationIgnored private let thumbnailBatcher: DropboxThumbnailBatcher
    @ObservationIgnored private var lastKnownAccountId: String?
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

        syncEngine?.start(accountId: accountId)
        DropboxLogger.info("DropboxPhotoStore: startSync() accountId=\(accountId)")
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

    // MARK: - Backup metadata

    /// バックアップフォルダの `.mosaic/metadata.json` をダウンロードして `backupMetadata` に保持する。
    /// バックアップ完了後、または起動時に呼び出す。
    public func loadBackupMetadata(from folderPath: String) async {
        let metaPath = folderPath + DropboxInternalConstants.backupMetadataSuffix
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: metaPath)) else { return }

        guard let data = try? await apiClient.contentDownload(
            url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else {
            DropboxLogger.info("loadBackupMetadata() — not found or error (\(metaPath))")
            return
        }
        guard let metadata = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: data) else {
            DropboxLogger.error("loadBackupMetadata() — JSON decode failed")
            return
        }
        backupMetadata = metadata
        DropboxLogger.info("loadBackupMetadata() — loaded \(metadata.entries.count) entries")
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

    // MARK: - Thumbnail

    /// サムネイルを返す。取得は `DropboxThumbnailBatcher` に委譲する
    /// （キャッシュ確認・バッチ集約・キャンセル耐性はバッチャ側に集約）。
    public func thumbnail(for item: DropboxFileItem) async -> UIImage? {
        await thumbnailBatcher.thumbnail(for: item)
    }

    /// スクロール先サムネイルの先読み。バッチャの**低優先・LIFO・上限つき**プールへ積む。
    /// キャッシュ済み（メモリ/ディスク）は `thumbnailExists` で除外しネットワークを使わない。
    /// 可視セル要求（`thumbnail(for:)`）が常に優先されるため、先読みが表示を遅らせない。
    public func prefetch(_ items: [DropboxFileItem], targetSize: CGSize) {
        thumbnailBatcher.prefetch(items)
    }

    /// 画面外へスクロールした先読みの取得を取り消す（無駄なネットワーク取得を止める）。
    /// `PhotoCollectionView` の `cancelPrefetchingForItemsAt` から呼ばれる。
    public func cancelPrefetch(_ items: [DropboxFileItem]) {
        thumbnailBatcher.cancelPrefetch(items)
    }

    // MARK: - Location

    /// 撮影地の座標。同期時に取れていれば即返し、無ければ get_metadata で単発取得して補完・保存する。
    public func location(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        if let coordinate = item.coordinate { return coordinate }

        struct Arg: Encodable { let path: String; let include_media_info = true }
        guard let body = try? JSONEncoder().encode(Arg(path: item.path)),
              let data = try? await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL, jsonBody: body)
        else { return nil }

        struct Meta: Decodable { let media_info: DropboxMediaInfo? }
        guard let loc = (try? JSONDecoder().decode(Meta.self, from: data))?.media_info?.metadata?.location else {
            return nil
        }
        await cache.updateLocation(path: item.path, latitude: loc.latitude, longitude: loc.longitude)
        return CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude)
    }

    /// ネット取得を伴わない座標。同期時に取れていれば返し、無ければ nil（get_metadata は叩かない）。
    /// フル表示の場所ラベル用：開くたびの 4〜6s の get_metadata 往復を避ける。
    public func cachedLocation(for item: DropboxFileItem) async -> CLLocationCoordinate2D? {
        item.coordinate
    }

    /// 前後ページのフル画像を**先読み**する（バイト列だけ取得・保存、デコードはしない）。
    /// 低優先で、すでにバイトがあれば何もしない。`beginFullImage` は立てない（背景埋め込みを
    /// 過度に止めないため）。表示時の `fullImage` がこのキャッシュを即ヒットして体感が軽くなる。
    public func prefetchFullImage(for item: DropboxFileItem) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            if await self.cache.fullImageData(for: item.path) != nil { return }
            struct Arg: Encodable { let path: String }
            guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return }
            guard let data = try? await self.apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return }
            await self.cache.storeFullImageData(data, for: item.path)
        }
    }

    // MARK: - Original data (for EXIF)

    /// 元画像の生データ（EXIF を含む）を返す。キャッシュ済みファイル優先、無ければダウンロード。
    /// EXIF 解析（PhotoSourceKit の PhotoExifInfo）は SwiftUI 層（DropboxKit）側で行う。
    public func originalImageData(for item: DropboxFileItem) async -> Data? {
        if let cached = await cache.fullImageData(for: item.path) {
            return cached
        }
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        return try? await apiClient.contentDownload(
            url: DropboxInternalConstants.downloadFileURL, apiArg: argString)
    }

    // MARK: - Full image

    public func fullImage(for item: DropboxFileItem) async -> UIImage? {
        let t0 = PerfTrace.nowNs()   // 計測: フル画像取得（キャッシュヒット or ダウンロード+デコード）
        if let cached = await cache.fullImage(for: item.path) {
            DropboxLogger.verbose("fullImage() cache hit — \(item.name)")
            PerfTrace.logSpan("fullImage.cacheHit", ms: PerfTrace.msSince(t0))
            return cached
        }
        DropboxLogger.verbose("fullImage() downloading from API — \(item.name)")
        struct Arg: Encodable { let path: String }
        guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
        DropboxActivityMonitor.shared.beginFullImage()
        defer { DropboxActivityMonitor.shared.endFullImage() }
        let data: Data
        do {
            data = try await apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString)
        } catch {
            DropboxLogger.error("fullImage() download failed — \(item.name): \(error.localizedDescription)")
            return nil
        }
        // ★ 元バイト列のままキャッシュ（EXIF 保持）。表示用は画面相当へダウンサンプルして
        //   常駐・一時メモリを抑える（ビューアはズーム無し＝フル解像度は不要）。
        await cache.storeFullImageData(data, for: item.path)
        let decoded = await Task.detached(priority: .userInitiated) {
            (ImageDownsampling.downsample(data: data)
                ?? UIImage(data: data).map { $0.preparingForDisplay() ?? $0 })
                .map(SendableUIImage.init)
        }.value
        guard let image = decoded?.image else { return nil }
        DropboxLogger.verbose("fullImage() downloaded \(data.count) bytes — \(item.name)")
        PerfTrace.logSpan("fullImage.download", ms: PerfTrace.msSince(t0), detail: "\(data.count / 1024)KB")
        return image
    }

    // MARK: - Album cover

    /// アルバムのカバー（タイトル写真）用の画像を返す。**128px サムネの拡大ではなく、フル画像から**
    /// `maxPixel` へダウンサンプルして生成するため粗くならない。フル画像バイトはキャッシュ優先で取得し、
    /// 無ければダウンロードして保存（ビューアと共用）。表示サイズ相当へ落とすので常駐メモリも軽い。
    public func coverImage(for item: DropboxFileItem, maxPixel: CGFloat) async -> UIImage? {
        let data: Data
        if let cached = await cache.fullImageData(for: item.path) {
            data = cached
        } else {
            struct Arg: Encodable { let path: String }
            guard let argString = encodeDropboxAPIArg(Arg(path: item.path)) else { return nil }
            DropboxActivityMonitor.shared.beginFullImage()
            defer { DropboxActivityMonitor.shared.endFullImage() }
            guard let downloaded = try? await apiClient.contentDownload(
                url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return nil }
            await cache.storeFullImageData(downloaded, for: item.path)   // 原バイト保存（EXIF 保持）
            data = downloaded
        }
        // カバーサイズへダウンサンプル（メイン外）。粗いサムネ拡大ではなく原画から作る。
        return await Task.detached(priority: .userInitiated) {
            ImageDownsampling.downsample(data: data, maxPixel: maxPixel).map(SendableUIImage.init)
        }.value?.image
    }

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
