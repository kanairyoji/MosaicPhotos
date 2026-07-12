#if canImport(UIKit)
import Foundation

/// バックグラウンドメタ情報同期エンジン。
///
/// 初回同期（カーソルなし）:
///   1. `list_folder/get_latest_cursor` でロングポール用ベースラインカーソルを先取り
///   2. ルートを非再帰スキャンしてルートファイルとトップレベルフォルダ一覧を取得
///   3. 各フォルダを最大 8 並列で再帰スキャン（limit:2000 でページ数を最小化）
///   4. 全結果を集約してキャッシュへ一括書き込み → ベースラインカーソルでポーリングへ
///
/// 差分同期（カーソルあり）:
///   `list_folder/longpoll` → `list_folder/continue` のループで差分のみ取得。
///
/// すべてのメソッドは MainActor 上で実行される。
/// ネットワーク呼び出しは `await` で Actor をブロックせずサスペンドするため、
/// UI レスポンシブ性を損なわない。
@MainActor
final class DropboxSyncEngine {

    // MARK: - Dependencies / callbacks

    private let apiClient: DropboxAPIClient
    private let cache: DropboxCacheStore
    /// キャッシュ更新後に MainActor 上で呼ばれるコールバック。
    private let onCacheUpdated: () -> Void
    /// 同期状態変化時に MainActor 上で呼ばれるコールバック。
    private let onStateChanged: (DropboxPhotoStore.SyncState) -> Void

    private var syncTask: Task<Void, Never>?

    // MARK: - Init

    init(
        apiClient: DropboxAPIClient,
        cache: DropboxCacheStore,
        onCacheUpdated: @escaping () -> Void,
        onStateChanged: @escaping (DropboxPhotoStore.SyncState) -> Void
    ) {
        self.apiClient = apiClient
        self.cache = cache
        self.onCacheUpdated = onCacheUpdated
        self.onStateChanged = onStateChanged
    }

    /// RPC を実行し、`DropboxAPIClient.APIError` を `SyncError` へ変換しつつログを残す。
    private func rpc(_ url: String, body: Data, endpoint: String) async throws -> Data {
        do {
            return try await apiClient.rpc(url: url, jsonBody: body)
        } catch let DropboxAPIClient.APIError.http(status, errBody) {
            DropboxLogger.error("SyncEngine: \(endpoint) HTTP \(status) — \(errBody.prefix(300))")
            throw SyncError.httpError(statusCode: status, body: errBody)
        }
    }

    // MARK: - Start / Stop

    func start(accountId: String) {
        stop()
        syncTask = Task { await syncLoop(accountId: accountId) }
        DropboxLogger.info("SyncEngine: start() accountId=\(accountId)")
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: - Sync loop entry point

    private func syncLoop(accountId: String) async {
        let cursor = (await cache.syncStateInfo(accountId: accountId))?.cursor
        let itemCount = await cache.cachedItemCount(accountId: accountId)
        // カーソルがあっても **アイテムが 0** ならキャッシュ不整合（取りこぼし・空のまま固定）とみなし、
        // ポーリングではなく初回スキャンをやり直して自己修復する（「接続済みなのに No photos」の解消）。
        if let cursor, itemCount > 0 {
            DropboxLogger.info("SyncEngine: cursor found (\(String(cursor.prefix(DropboxInternalConstants.cursorLogPrefixLong)))...), \(itemCount) items — entering poll loop")
            await pollLoop(accountId: accountId, startCursor: cursor)
        } else {
            DropboxLogger.info("SyncEngine: \(cursor == nil ? "no cursor" : "cursor present but 0 items") — starting initial sync")
            await initialSync(accountId: accountId)
        }
    }

    // MARK: - Parallel initial sync

    private func initialSync(accountId: String) async {
        do {
            onStateChanged(.initialSync(fetched: 0))

            // Step 1: ロングポールのベースラインカーソルをスキャン開始前に確保。
            // これにより、スキャン中の変更はポーリングフェーズで差分として拾われる。
            let baselineCursor = try await getLatestCursor()
            guard !Task.isCancelled else { onStateChanged(.idle); return }
            DropboxLogger.info("SyncEngine: baseline cursor acquired")

            // Step 2: ルートの非再帰スキャン（ルート直下ファイル + トップレベルフォルダ一覧）
            var rootImages: [DropboxFileItem] = []
            var topFolders: [String] = []
            var shallowCursor: String? = nil
            var shallowHasMore = true
            while shallowHasMore {
                guard !Task.isCancelled else { onStateChanged(.idle); return }
                let page = try await fetchDeltaPage(cursor: shallowCursor, path: "", recursive: false)
                rootImages.append(contentsOf: page.added)
                topFolders.append(contentsOf: page.subfolderPaths)
                shallowCursor = page.cursor
                shallowHasMore = page.hasMore
            }
            DropboxLogger.info("SyncEngine: root scan — \(rootImages.count) root images, \(topFolders.count) top-level folders")

            var allImages = rootImages

            // ルート直下の画像をすぐに書き込む（フォルダスキャン中も即表示）
            if !rootImages.isEmpty {
                await cache.applyDelta(accountId: accountId,
                                 added: rootImages, removed: [],
                                 newCursor: baselineCursor)
                onCacheUpdated()
            }

            // Step 3: 各トップレベルフォルダを順番に再帰スキャン。
            // ⚠️ withThrowingTaskGroup で @MainActor タスクを並列化すると iOS 17 で
            //    group の結果が返ってこなくなる問題が発生したため、逐次処理に変更。
            //    @MainActor 上では await ごとにアクターを手放すため
            //    UI 応答性は損なわれない。
            // ⚠️ ページ単位で即時書き込む（ページ完了ごとに applyDelta + onCacheUpdated）。
            //    以前はフォルダの全ページ完了後に一括書き込みしていたが、
            //    万件規模の Dropbox では全ページ完了まで UI がスピナーのままになる問題があった。
            for folderPath in topFolders {
                guard !Task.isCancelled else { onStateChanged(.idle); return }
                var cur: String? = nil
                var more = true
                while more {
                    guard !Task.isCancelled else { onStateChanged(.idle); return }
                    let pg = try await fetchDeltaPage(cursor: cur, path: folderPath, recursive: true)
                    if !pg.added.isEmpty {
                        allImages.append(contentsOf: pg.added)
                        await cache.applyDelta(accountId: accountId,
                                         added: pg.added, removed: [],
                                         newCursor: baselineCursor)
                        onStateChanged(.initialSync(fetched: allImages.count))
                        onCacheUpdated()
                    }
                    cur = pg.cursor
                    more = pg.hasMore
                }
            }

            guard !Task.isCancelled else { onStateChanged(.idle); return }

            // Step 4: 古いキャッシュエントリを除去し、最終カーソルを確実に保存。
            let cachedPaths = Set(await cache.cachedItems(accountId: accountId).map(\.path))
            let fetchedPaths = Set(allImages.map(\.path))
            let stalePaths = Array(cachedPaths.subtracting(fetchedPaths))

            await cache.applyDelta(accountId: accountId,
                             added: [], removed: stalePaths,
                             newCursor: baselineCursor)
            // 空 Dropbox・ stale 削除・画像なしの場合も必ず onCacheUpdated を呼び
            // .polling 移行前に state を確定させる。
            onCacheUpdated()
            DropboxLogger.info("SyncEngine: initial sync complete — \(allImages.count) images, \(stalePaths.count) stale removed")

            await pollLoop(accountId: accountId, startCursor: baselineCursor)

        } catch is CancellationError {
            onStateChanged(.idle)
        } catch {
            DropboxLogger.error("SyncEngine: initial sync error — \(error.localizedDescription)")
            onStateChanged(.error(error.localizedDescription))
        }
    }

    // MARK: - Longpoll loop

    private func pollLoop(accountId: String, startCursor: String) async {
        var cursor = startCursor

        while !Task.isCancelled {
            onStateChanged(.polling)

            do {
                let result = try await longpoll(cursor: cursor)
                guard !Task.isCancelled else { break }

                if let backoff = result.backoff, backoff > 0 {
                    DropboxLogger.verbose("SyncEngine: backoff \(backoff)s")
                    try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                }

                if result.changes {
                    onStateChanged(.fetchingDelta)
                    var deltaHasMore = true
                    while deltaHasMore && !Task.isCancelled {
                        let page = try await fetchDeltaPage(cursor: cursor)
                        deltaHasMore = page.hasMore
                        cursor = page.cursor
                        await cache.applyDelta(accountId: accountId,
                                         added: page.added, removed: page.removed,
                                         newCursor: page.cursor)
                        if !page.added.isEmpty || !page.removed.isEmpty {
                            onCacheUpdated()
                            DropboxLogger.info("SyncEngine: delta — +\(page.added.count), -\(page.removed.count)")
                        } else {
                            DropboxLogger.verbose("SyncEngine: delta — no image changes, cursor advanced")
                        }
                    }
                } else {
                    DropboxLogger.verbose("SyncEngine: longpoll — no changes")
                    // longpoll が即座に返った場合（本番では稀・テストのスタブでは常時）に、
                    // 待ち無しで再 longpoll するとビジーループ化して main actor を飢餓させる。
                    // 最小待ちを入れて協調的にする（cancel されたら即 break）。
                    try await Task.sleep(nanoseconds: DropboxInternalConstants.pollNoChangeMinDelayNs)
                    guard !Task.isCancelled else { break }
                }

            } catch is CancellationError {
                break
            } catch {
                DropboxLogger.error("SyncEngine: poll error — \(error.localizedDescription)")
                onStateChanged(.error(error.localizedDescription))
                do {
                    try await Task.sleep(nanoseconds: DropboxInternalConstants.retryDelayNs)
                } catch {
                    break
                }
            }
        }

        onStateChanged(.idle)
        DropboxLogger.info("SyncEngine: poll loop ended")
    }

    // MARK: - Network: list_folder/get_latest_cursor

    /// 現時点の最新カーソルを取得する。ファイル一覧は返さない。
    /// 並列初回スキャン前に呼び出し、スキャン中の変更をポーリングで拾う起点とする。
    private func getLatestCursor() async throws -> String {
        struct Body: Encodable {
            let path = ""
            let recursive = true
            let limit = DropboxInternalConstants.listFolderPageLimit
        }
        struct Response: Decodable { let cursor: String }

        let data = try await rpc(
            DropboxInternalConstants.listFolderLatestCursorURL,
            body: try JSONEncoder().encode(Body()),
            endpoint: "getLatestCursor")
        return try JSONDecoder().decode(Response.self, from: data).cursor
    }

    // MARK: - Network: list_folder / list_folder/continue

    /// `cursor` が nil の場合は `list_folder`（path/recursive を使用）、
    /// 非 nil の場合は `list_folder/continue`（path/recursive は無視）を呼び出す。
    /// レスポンスの解析は純ロジックの `DeltaPageParser` に委譲する。
    private func fetchDeltaPage(
        cursor: String?,
        path: String = "",
        recursive: Bool = true
    ) async throws -> DeltaPage {
        let url: String
        let body: Data
        if let cursor {
            struct Body: Encodable { let cursor: String }
            url = DropboxInternalConstants.listFolderContinueURL
            body = try JSONEncoder().encode(Body(cursor: cursor))
        } else {
            // include_media_info=true で各ファイルの media_info（撮影地・撮影日時）を取得する。
            // continue 側は元の list_folder の設定を引き継ぐため指定不要。
            struct Body: Encodable {
                let path: String
                let recursive: Bool
                let limit = DropboxInternalConstants.listFolderPageLimit
                let include_media_info = true
            }
            url = DropboxInternalConstants.listFolderURL
            body = try JSONEncoder().encode(Body(path: path, recursive: recursive))
        }

        let data = try await rpc(url, body: body, endpoint: "fetchDeltaPage")
        let page = try DeltaPageParser.parse(data)

        DropboxLogger.info(
            "SyncEngine: fetchDeltaPage path=\(path.isEmpty ? "/" : path) " +
            "← cursor=\(cursor.map { String($0.prefix(DropboxInternalConstants.cursorLogPrefixShort)) } ?? "nil") " +
            "→ +\(page.added.count) imgs, \(page.subfolderPaths.count) folders, hasMore=\(page.hasMore)")

        return page
    }

    // MARK: - Network: list_folder/longpoll

    /// Dropbox longpoll。変更があれば `changes = true` を返す。
    /// longpoll エンドポイントは Authorization ヘッダー不要。
    private func longpoll(cursor: String) async throws -> (changes: Bool, backoff: Int?) {
        struct Body: Encodable { let cursor: String; let timeout = DropboxInternalConstants.longpollTimeoutSeconds }
        struct Response: Decodable { let changes: Bool; let backoff: Int? }

        let data: Data
        do {
            // longpoll は認証不要・専用タイムアウト。
            data = try await apiClient.rpcNoAuth(
                url: DropboxInternalConstants.listFolderLongpollURL,
                jsonBody: try JSONEncoder().encode(Body(cursor: cursor)),
                timeout: DropboxInternalConstants.longpollURLRequestTimeout)
        } catch let DropboxAPIClient.APIError.http(status, errBody) {
            DropboxLogger.error("SyncEngine: longpoll HTTP \(status) — \(errBody.prefix(200))")
            throw SyncError.httpError(statusCode: status, body: errBody)
        }

        let result = try JSONDecoder().decode(Response.self, from: data)
        DropboxLogger.verbose("SyncEngine: longpoll ← changes=\(result.changes), backoff=\(result.backoff ?? 0)")
        return (result.changes, result.backoff)
    }

    // MARK: - Errors

    private enum SyncError: LocalizedError {
        case invalidResponse
        case httpError(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid server response."
            case .httpError(let code, _): return "HTTP \(code)"
            }
        }
    }
}
#endif
