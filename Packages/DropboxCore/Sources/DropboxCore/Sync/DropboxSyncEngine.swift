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

    /// 同期を開始する（ADR-44: マルチルート対応）。
    /// - Parameter roots: 同期対象ルートの配列（正規化済み・非包含）。"" = アカウント全体。
    ///   先頭がユーザー選択のソースフォルダ（UI 状態を駆動）、以降はバックアップフォルダ等の
    ///   追加スコープ（**静かに**同期＝UI 状態を変えない・エラーのみログ）。
    func start(accountId: String, roots: [String] = [""]) {
        stop()
        let effectiveRoots = roots.isEmpty ? [""] : roots
        syncTask = Task { await syncAll(accountId: accountId, roots: effectiveRoots) }
        DropboxLogger.info("SyncEngine: start() accountId=\(accountId) roots=\(effectiveRoots.map { $0.isEmpty ? "/" : $0 })")
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    // MARK: - Sync loop entry point

    /// ルートごとの同期ループを並行に走らせる（通常 1〜2 本）。
    private func syncAll(accountId: String, roots: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, root) in roots.enumerated() {
                let isPrimary = (index == 0)
                group.addTask { @MainActor [weak self] in
                    await self?.syncLoop(accountId: accountId, root: root, isPrimary: isPrimary)
                }
            }
            await group.waitForAll()
        }
    }

    /// カーソルの保存キー。ルート "" は従来どおり素の accountId（既存インストールのカーソルを
    /// 生かし、全体スコープのままの更新で不要な全再同期を起こさない）。フォルダルートは
    /// "accountId|/path" の複合キー（DropboxSyncState の行を流用・アイテムはグローバル共有）。
    private static func scopeKey(accountId: String, root: String) -> String {
        root.isEmpty ? accountId : accountId + "|" + root.lowercased()
    }

    private func syncLoop(accountId: String, root: String, isPrimary: Bool) async {
        let scopeKey = Self.scopeKey(accountId: accountId, root: root)
        let cursor = (await cache.syncStateInfo(accountId: scopeKey))?.cursor
        let itemCount = await cache.cachedItemCount(accountId: accountId)
        // カーソルがあっても **アイテムが 0** ならキャッシュ不整合（取りこぼし・空のまま固定）とみなし、
        // ポーリングではなく初回スキャンをやり直して自己修復する（「接続済みなのに No photos」の解消）。
        if let cursor, itemCount > 0 {
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: cursor found (\(String(cursor.prefix(DropboxInternalConstants.cursorLogPrefixLong)))...), \(itemCount) items — entering poll loop")
            await pollLoop(scopeKey: scopeKey, startCursor: cursor, isPrimary: isPrimary)
        } else {
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: \(cursor == nil ? "no cursor" : "cursor present but 0 items") — starting initial sync")
            await initialSync(accountId: accountId, root: root, scopeKey: scopeKey, isPrimary: isPrimary)
        }
    }

    /// UI 状態の報告（プライマリルートのみ）。追加ルートは静かに同期する。
    private func reportState(_ state: DropboxPhotoStore.SyncState, isPrimary: Bool) {
        if isPrimary { onStateChanged(state) }
    }

    // MARK: - Parallel initial sync

    private func initialSync(accountId: String, root: String, scopeKey: String, isPrimary: Bool) async {
        do {
            reportState(.initialSync(fetched: 0), isPrimary: isPrimary)

            // Step 1: ロングポールのベースラインカーソルをスキャン開始前に確保。
            // これにより、スキャン中の変更はポーリングフェーズで差分として拾われる。
            let baselineCursor = try await getLatestCursor(path: root)
            guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return }
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: baseline cursor acquired")

            // Step 2: スキャン対象フォルダ列を決める。
            // - 全体（root == ""）: ルートの非再帰スキャン → ルート直下ファイル＋トップレベルフォルダ列
            //   （フォルダごとに進捗書き込み＝万件規模でスピナー固定を防ぐ従来方式）。
            // - フォルダ指定: そのフォルダ 1 本を再帰スキャン（ページ単位で進捗書き込み）。
            var allImages: [DropboxFileItem] = []
            var scanFolders: [String] = []
            if root.isEmpty {
                var topFolders: [String] = []
                var shallowCursor: String? = nil
                var shallowHasMore = true
                while shallowHasMore {
                    guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return }
                    let page = try await fetchDeltaPage(cursor: shallowCursor, path: "", recursive: false)
                    allImages.append(contentsOf: page.added)
                    topFolders.append(contentsOf: page.subfolderPaths)
                    shallowCursor = page.cursor
                    shallowHasMore = page.hasMore
                }
                DropboxLogger.info("SyncEngine: root scan — \(allImages.count) root images, \(topFolders.count) top-level folders")
                // ルート直下の画像をすぐに書き込む（フォルダスキャン中も即表示）
                if !allImages.isEmpty {
                    await cache.applyDelta(accountId: scopeKey,
                                     added: allImages, removed: [],
                                     newCursor: baselineCursor)
                    onCacheUpdated()
                }
                scanFolders = topFolders
            } else {
                scanFolders = [root]
            }

            // Step 3: 各フォルダを順番に再帰スキャン。
            // ⚠️ withThrowingTaskGroup で @MainActor タスクを並列化すると iOS 17 で
            //    group の結果が返ってこなくなる問題が発生したため、逐次処理に変更。
            // ⚠️ ページ単位で即時書き込む（ページ完了ごとに applyDelta + onCacheUpdated）。
            for folderPath in scanFolders {
                guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return }
                var cur: String? = nil
                var more = true
                while more {
                    guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return }
                    let pg = try await fetchDeltaPage(cursor: cur, path: folderPath, recursive: true)
                    if !pg.added.isEmpty {
                        allImages.append(contentsOf: pg.added)
                        await cache.applyDelta(accountId: scopeKey,
                                         added: pg.added, removed: [],
                                         newCursor: baselineCursor)
                        reportState(.initialSync(fetched: allImages.count), isPrimary: isPrimary)
                        onCacheUpdated()
                    }
                    cur = pg.cursor
                    more = pg.hasMore
                }
            }

            guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return }

            // Step 4: 古いキャッシュエントリを除去し、最終カーソルを確実に保存。
            // ⚠️ prune は**このルートの配下だけ**を対象にする（マルチルートで他ルートの
            //    アイテムを消さない）。root == "" は正規化により単独なので全体が対象。
            let prefix = root.isEmpty ? "" : root.lowercased() + "/"
            let cachedPaths = Set(await cache.cachedItems(accountId: accountId).map(\.path)
                .filter { prefix.isEmpty || $0.lowercased().hasPrefix(prefix) })
            let fetchedPaths = Set(allImages.map(\.path))
            let stalePaths = Array(cachedPaths.subtracting(fetchedPaths))

            await cache.applyDelta(accountId: scopeKey,
                             added: [], removed: stalePaths,
                             newCursor: baselineCursor)
            // 空 Dropbox・ stale 削除・画像なしの場合も必ず onCacheUpdated を呼び
            // .polling 移行前に state を確定させる。
            onCacheUpdated()
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: initial sync complete — \(allImages.count) images, \(stalePaths.count) stale removed")

            await pollLoop(scopeKey: scopeKey, startCursor: baselineCursor, isPrimary: isPrimary)

        } catch is CancellationError {
            reportState(.idle, isPrimary: isPrimary)
        } catch {
            DropboxLogger.error("SyncEngine[\(root.isEmpty ? "/" : root)]: initial sync error — \(error.localizedDescription)")
            reportState(.error(error.localizedDescription), isPrimary: isPrimary)
        }
    }

    // MARK: - Longpoll loop

    private func pollLoop(scopeKey: String, startCursor: String, isPrimary: Bool) async {
        var cursor = startCursor

        while !Task.isCancelled {
            reportState(.polling, isPrimary: isPrimary)

            do {
                let result = try await longpoll(cursor: cursor)
                guard !Task.isCancelled else { break }

                if let backoff = result.backoff, backoff > 0 {
                    DropboxLogger.verbose("SyncEngine: backoff \(backoff)s")
                    try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                }

                if result.changes {
                    reportState(.fetchingDelta, isPrimary: isPrimary)
                    var deltaHasMore = true
                    while deltaHasMore && !Task.isCancelled {
                        let page = try await fetchDeltaPage(cursor: cursor)
                        deltaHasMore = page.hasMore
                        cursor = page.cursor
                        await cache.applyDelta(accountId: scopeKey,
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
                reportState(.error(error.localizedDescription), isPrimary: isPrimary)
                do {
                    try await Task.sleep(nanoseconds: DropboxInternalConstants.retryDelayNs)
                } catch {
                    break
                }
            }
        }

        reportState(.idle, isPrimary: isPrimary)
        DropboxLogger.info("SyncEngine: poll loop ended")
    }

    // MARK: - Network: list_folder/get_latest_cursor

    /// 現時点の最新カーソルを取得する。ファイル一覧は返さない。
    /// 並列初回スキャン前に呼び出し、スキャン中の変更をポーリングで拾う起点とする。
    private func getLatestCursor(path: String = "") async throws -> String {
        struct Body: Encodable {
            let path: String
            let recursive = true
            let limit = DropboxInternalConstants.listFolderPageLimit
        }
        struct Response: Decodable { let cursor: String }

        let data = try await rpc(
            DropboxInternalConstants.listFolderLatestCursorURL,
            body: try JSONEncoder().encode(Body(path: path)),
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
