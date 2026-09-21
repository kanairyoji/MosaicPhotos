#if canImport(UIKit)
import Foundation
import MosaicSupport

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
    /// キャッシュ更新の通知。引数は**この更新で追加/削除されたパス（小文字）**。
    /// 空配列は「全体が変わり得る」（初期同期の確定・stale 削除など）＝必ず反映すること。
    private let onCacheUpdated: (_ changedPathsLower: [String]) -> Void
    /// 同期状態変化時に MainActor 上で呼ばれるコールバック。
    private let onStateChanged: (DropboxPhotoStore.SyncState) -> Void

    private var syncTask: Task<Void, Never>?

    /// いずれかのルートが**全件の見直し中**か（ADR-206）。
    ///
    /// ⚠️ ルートは 3 本（ソース・バックアップ・家族）が並行に回っていて、どれも
    /// **同じ日に初回同期を終えている**。期限も同じ日に来るので、素直に書くと
    /// 3 本が同じ窓で一斉に全件一覧を引く。窓は数分しかないので、揃って中途半端に
    /// 終わって誰も印を進められない——次の窓でまた 3 本が一斉に始まる。1 本ずつにする。
    private var isReconcilingAnyRoot = false

    /// 見直しに失敗したルート（この起動のあいだは再挑戦しない）。
    ///
    /// ⚠️ 失敗のたびに投げ直すと、通信が不調な端末で**ポーリングが見直しに食われる**。
    /// 次の起動でやり直せばよい（印は進めていないので期限は来たまま）。
    private var reconcileFailedRoots: Set<String> = []

    // MARK: - Init

    init(
        apiClient: DropboxAPIClient,
        cache: DropboxCacheStore,
        onCacheUpdated: @escaping (_ changedPathsLower: [String]) -> Void,
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
        // ⚠️ **カーソル失効からやり直せるようにする**（ADR-203）。Dropbox は差分カーソルを
        // 失効させることがあり（`continue` が `reset`）、失効したカーソルは二度と有効に
        // ならない。以前はこれを一時エラーとして 30 秒ごとに投げ直していたため、
        // **同期が永久に止まっていた**（利用者からは「新しい写真が出てこない」）。
        while !Task.isCancelled {
            guard await syncOnce(accountId: accountId, root: root, isPrimary: isPrimary) else { return }
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: cursor was reset — starting over")
        }
    }

    /// - Returns: **やり直しが要るか**（カーソル失効）。false なら終了してよい。
    private func syncOnce(accountId: String, root: String, isPrimary: Bool) async -> Bool {
        let scopeKey = Self.scopeKey(accountId: accountId, root: root)
        let state = await cache.syncStateInfo(accountId: scopeKey)
        let cursor = state?.cursor
        let itemCount = await cache.cachedItemCount(accountId: accountId)
        // poll へ直行してよいのは、次の 3 つが揃ったときだけ。
        // - カーソルがある
        // - アイテムがある（0 ならキャッシュ不整合＝「接続済みなのに No photos」の自己修復）
        // - **初回スキャンを完走している**
        //   ⚠️ カーソルはスキャン中にも書かれるため、「カーソルがある＝走査済み」ではない。
        //   途中で終了すると「一部の写真＋カーソル」が残り、次回起動が poll へ直行して
        //   **未走査フォルダの既存写真が永久に取得されない**（レビュー指摘）。
        // ⚠️ **週 1 回は全件を見直す**（ADR-206）。差分は「消えた」通知を取りこぼすと
        // その行が永久に残るので、掃除しに来る経路が要る。掃除の処理は初回同期が持っている
        // ので、期限が来たらそれをやり直すだけでよい。
        // ⚠️ **前面では走らせない**。8 万件の一覧は一枚岩の通信処理（ADR-107）。
        let reconcileDue = shouldReconcileNow(scopeKey: scopeKey,
                                              lastFullScan: state?.initialSyncCompletedAt)
        // ⚠️ **確保は判定の直後**（`await` を挟まない）。挟むと、その中断のあいだに
        // 別のルートが同じ判定を通り抜けて、2 本同時に全件一覧を引く。
        // ルートは 3 本とも同じ日に初回同期を終えている＝期限も同じ日に来るので、
        // これは「たまに起きる」ではなく**必ず起きる**。
        if reconcileDue { isReconcilingAnyRoot = true }
        if let cursor, itemCount > 0, state?.isInitialSyncCompleted == true, !reconcileDue {
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: cursor found (\(String(cursor.prefix(DropboxInternalConstants.cursorLogPrefixLong)))...), \(itemCount) items — entering poll loop")
            return await pollLoop(scopeKey: scopeKey, root: root, startCursor: cursor,
                                  isPrimary: isPrimary,
                                  lastFullScan: state?.initialSyncCompletedAt)
        } else {
            let reason = cursor == nil ? "no cursor"
                : itemCount == 0 ? "cursor present but 0 items"
                : reconcileDue ? "weekly reconcile due"
                : "initial sync never completed (interrupted or pre-upgrade)"
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: \(reason) — starting initial sync")
            return await initialSync(accountId: accountId, root: root, scopeKey: scopeKey,
                                     isPrimary: isPrimary, isReconcile: reconcileDue)
        }
    }

    /// いま全件の見直しに入ってよいか。**期限・重い通信の可否・他のルートの都合**を見る。
    ///
    /// ⚠️ 判定を 1 か所に置く（`syncOnce` と `pollLoop` が同じ式を使う）。別々に書くと、
    /// 片方が「やり直せ」と言って片方が「まだ」と言う状態になり、やり直しの合図だけが
    /// 空回りする——ADR-196 で畳んだ「入口と譲りで違う条件」と同じ形。
    private func shouldReconcileNow(scopeKey: String, lastFullScan: Date?,
                                    now: Date = Date()) -> Bool {
        guard !isReconcilingAnyRoot, !reconcileFailedRoots.contains(scopeKey) else { return false }
        return CloudReconcilePolicy.isDue(lastFullScan: lastFullScan, now: now)
            && BackgroundYield.allows(.cloudMonolith)
    }

    /// UI 状態の報告（プライマリルートのみ）。追加ルートは静かに同期する。
    private func reportState(_ state: DropboxPhotoStore.SyncState, isPrimary: Bool) {
        if isPrimary { onStateChanged(state) }
    }

    // MARK: - Parallel initial sync

    /// - Returns: **やり直しが要るか**（後続の poll でカーソルが失効した場合）。
    /// - Parameter isReconcile: 週次の見直し（ADR-206）か。**進捗を画面へ出さない**——
    ///   キャッシュは既に埋まっていて、利用者から見れば何も起きていないのが正しい状態。
    ///   「同期中」を出すと、週に 1 度だけ理由もなく進捗が走るように見える。
    private func initialSync(accountId: String, root: String, scopeKey: String,
                             isPrimary: Bool, isReconcile: Bool = false) async -> Bool {
        // 確保は `syncOnce` が済ませている（判定と地続きにするため）。ここでは返すだけ。
        //
        // ⚠️ **`defer` だけに任せない**（クラウドレビューの指摘・レビュー 5 周目）。
        // この関数は全件走査のあと `return await pollLoop(...)` で**末尾呼び出し**するので、
        // `defer` が走るのは pollLoop が返ったとき——つまりカーソル失効・ルート消失・
        // 取り消しが起きるまで走らない。結果、確保が返らず
        // **「1 本ずつ」ではなく「最初の 1 本だけ」**になっていた（他のルートは
        // そのセッション中ずっと見直されない）。走査を終えた時点で明示的に返す。
        // `defer` は取りこぼし（throw・途中 return）の安全弁として残す。
        func releaseReconcileSlot() { if isReconcile { isReconcilingAnyRoot = false } }
        defer { releaseReconcileSlot() }
        do {
            if !isReconcile { reportState(.initialSync(fetched: 0), isPrimary: isPrimary) }

            // Step 1: ロングポールのベースラインカーソルをスキャン開始前に確保。
            // これにより、スキャン中の変更はポーリングフェーズで差分として拾われる。
            let baselineCursor = try await getLatestCursor(path: root)
            guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return false }
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
                    guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return false }
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
                    onCacheUpdated(allImages.map { $0.path.lowercased() })
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
                guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return false }
                var cur: String? = nil
                var more = true
                while more {
                    guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return false }
                    let pg = try await fetchDeltaPage(cursor: cur, path: folderPath, recursive: true)
                    if !pg.added.isEmpty {
                        allImages.append(contentsOf: pg.added)
                        await cache.applyDelta(accountId: scopeKey,
                                         added: pg.added, removed: [],
                                         newCursor: baselineCursor)
                        if !isReconcile {
                            reportState(.initialSync(fetched: allImages.count), isPrimary: isPrimary)
                        }
                        onCacheUpdated(pg.added.map { $0.path.lowercased() })
                    }
                    cur = pg.cursor
                    more = pg.hasMore
                }
            }

            guard !Task.isCancelled else { reportState(.idle, isPrimary: isPrimary); return false }

            // Step 4: 古いキャッシュエントリを除去し、最終カーソルを確実に保存。
            // ⚠️ prune は**このルートの配下だけ**を対象にする（マルチルートで他ルートの
            //    アイテムを消さない）。root == "" は正規化により単独なので全体が対象。
            let prefix = root.isEmpty ? "" : root.lowercased() + "/"
            // ⚠️ 要るのは**パスの集合だけ**。`cachedItems` は全列を実体化して値型を
            //    7 万個作るので、ここでは射影（`cachedPaths`）を使う。
            let cachedPaths = Set(await cache.cachedPaths(withPrefix: prefix))
            let fetchedPaths = Set(allImages.map(\.path))
            let stalePaths = Array(cachedPaths.subtracting(fetchedPaths))

            await cache.applyDelta(accountId: scopeKey,
                             added: [], removed: stalePaths,
                             newCursor: baselineCursor)
            // 空 Dropbox・ stale 削除・画像なしの場合も必ず onCacheUpdated を呼び
            // .polling 移行前に state を確定させる（空配列＝全体反映）。
            onCacheUpdated([])
            // ここまで来て初めて「走査済み」。以後の起動は poll へ直行してよい。
            // ⚠️ この時刻は「最後に全件を見終えた時刻」でもある（ADR-206 の照合の基準）。
            let completedAt = Date()
            await cache.markInitialSyncCompleted(accountId: scopeKey, at: completedAt)
            DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: \(isReconcile ? "weekly reconcile" : "initial sync") complete — \(allImages.count) images, \(stalePaths.count) stale removed")

            releaseReconcileSlot()   // 走査はここで終わり。次のルートへ譲る。
            return await pollLoop(scopeKey: scopeKey, root: root,
                                  startCursor: baselineCursor, isPrimary: isPrimary,
                                  lastFullScan: completedAt)

        } catch is CancellationError {
            reportState(.idle, isPrimary: isPrimary)
        } catch {
            DropboxLogger.error("SyncEngine[\(root.isEmpty ? "/" : root)]: \(isReconcile ? "weekly reconcile" : "initial sync") error — \(error.localizedDescription)")
            // ⚠️ **見直しの失敗で、動いていたポーリングまで止めない**（ADR-206 のレビュー 1 周目）。
            // 週次の見直しは利用者が頼んだ処理ではなく、キャッシュは既に揃っている。
            // ここで `false` を返すと `syncLoop` が抜けて**そのルートの同期がアプリを
            // 開き直すまで止まる**——通信が一瞬切れただけで、新しい写真が出てこなくなる。
            // `.error` を画面へ出すのも筋が違う（利用者から見れば何も起きていない。
            // しかも `.error` は共有の取り込みの掃除まで止める＝`cacheSettled`）。
            if isReconcile {
                reconcileFailedRoots.insert(scopeKey)
                let state = await cache.syncStateInfo(accountId: scopeKey)
                if let cursor = state?.cursor, !Task.isCancelled {
                    DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: "
                        + "reconcile failed — back to polling (will retry next launch)")
                    releaseReconcileSlot()   // 失敗でも走査は終わり。次のルートへ譲る。
                    return await pollLoop(scopeKey: scopeKey, root: root, startCursor: cursor,
                                          isPrimary: isPrimary,
                                          lastFullScan: state?.initialSyncCompletedAt)
                }
            }
            reportState(.error(error.localizedDescription), isPrimary: isPrimary)
        }
        return false
    }

    // MARK: - Longpoll loop

    /// - Parameter lastFullScan: 最後に全件を見終えた時刻（週次の見直しの基準・ADR-206）。
    ///   ポーリング中は変わらないので、入るときに 1 度もらって持っておく。
    /// - Returns: **やり直しが要るか**（カーソル失効・ルート消失・週次の見直し）。
    private func pollLoop(scopeKey: String, root: String, startCursor: String,
                          isPrimary: Bool, lastFullScan: Date?) async -> Bool {
        var cursor = startCursor
        /// 「変化あり」と言われたのに**表示対象の増減が 0 だった**周の連続数（diagnostics-81）。
        /// 自分のバックアップ・共有コピーが同じルートへ落ちると延々と立つので、ここで間隔を空ける。
        var emptyStreak = 0

        while !Task.isCancelled {
            reportState(.polling, isPrimary: isPrimary)

            do {
                let result = try await longpoll(cursor: cursor)
                guard !Task.isCancelled else { break }

                // ⚠️ **判定は longpoll の後**（ADR-206）。周の先頭に置くと、`syncOnce` が
                // 「まだ動かしてよい時間ではない」と判断して poll へ戻した瞬間に
                // ここがまた true を返し、通信を 1 度もせずに回り続ける（タイトループ）。
                // 後ろに置けば、最悪でも 1 周 1 longpoll のコストが入る。
                if shouldReconcileNow(scopeKey: scopeKey, lastFullScan: lastFullScan) {
                    DropboxLogger.info("SyncEngine[\(root.isEmpty ? "/" : root)]: "
                        + "weekly reconcile due — re-listing to drop anything that is gone")
                    return true
                }

                if let backoff = result.backoff, backoff > 0 {
                    DropboxLogger.verbose("SyncEngine: backoff \(backoff)s")
                    try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000_000)
                    guard !Task.isCancelled else { break }
                }

                if result.changes {
                    reportState(.fetchingDelta, isPrimary: isPrimary)
                    var deltaHasMore = true
                    var sawRealChange = false
                    while deltaHasMore && !Task.isCancelled {
                        let page = try await fetchDeltaPage(cursor: cursor)
                        deltaHasMore = page.hasMore
                        cursor = page.cursor
                        await cache.applyDelta(accountId: scopeKey,
                                         added: page.added, removed: page.removed,
                                         newCursor: page.cursor)
                        if !page.added.isEmpty || !page.removed.isEmpty {
                            sawRealChange = true
                            onCacheUpdated(page.added.map { $0.path.lowercased() }
                                + page.removed.map { $0.lowercased() })
                            DropboxLogger.info("SyncEngine: delta — +\(page.added.count), -\(page.removed.count)")
                        } else {
                            DropboxLogger.verbose("SyncEngine: delta — no image changes, cursor advanced")
                        }
                    }
                    // ⚠️ **変化ありでも間隔を空ける**（diagnostics-81）。自分のアップロードが
                    //    同じルートに落ちると changes=true が鳴り続け、待ちが無いと
                    //    「longpoll → delta（空）→ longpoll」を無停止で回してしまう。
                    //    本物の変化があれば streak を 0 に戻すので、追従の速さは変わらない。
                    emptyStreak = sawRealChange ? 0 : emptyStreak + 1
                    if emptyStreak == 1 || emptyStreak % 20 == 0 {
                        DropboxLogger.verbose("SyncEngine: empty delta streak=\(emptyStreak) — pacing polls")
                    }
                    try await Task.sleep(nanoseconds: SyncPollPacing.delayNs(emptyStreak: emptyStreak))
                    guard !Task.isCancelled else { break }
                } else {
                    DropboxLogger.verbose("SyncEngine: longpoll — no changes")
                    emptyStreak = 0
                    // longpoll が即座に返った場合（本番では稀・テストのスタブでは常時）に、
                    // 待ち無しで再 longpoll するとビジーループ化して main actor を飢餓させる。
                    // 最小待ちを入れて協調的にする（cancel されたら即 break）。
                    try await Task.sleep(nanoseconds: DropboxInternalConstants.pollNoChangeMinDelayNs)
                    guard !Task.isCancelled else { break }
                }

            } catch is CancellationError {
                break
            } catch let error as SyncError where error.isCursorReset {
                // ⚠️ 失効したカーソルは**二度と有効にならない**。捨てて一覧から作り直す。
                DropboxLogger.error("SyncEngine: cursor reset — discarding it and re-syncing")
                await cache.resetSyncCursor(accountId: scopeKey)
                return true
            } catch let error as SyncError where error.isPathNotFound && !root.isEmpty {
                // ⚠️ **ルートそのものが無い**（消された・名前が変わった・共有が解除された）。
                // ⚠️ **アカウント全体（root == ""）は対象外**（レビュー 2 周目）。掃除の範囲は
                // 「このルートの配下」で、root が空だと**キャッシュ全体**になる。
                // アカウントのルートは消えようがないので、そこで not_found が返るのは
                // こちらの読み違いか想定外の応答——得るものが無いのに 8 万行を捨てる。
                // これも一時エラーではないので、投げ直しても永久に 409 が返る。
                // 実機ログ（diagnostics-82）では家族フォルダが消えたまま 18 日間・30 秒ごとに
                // 409 を出し続け、そのルートのキャッシュ 8,513 行が**開けない写真として
                // 一覧に残り続けた**（「ファイルがありません」）。差分が二度と届かない以上、
                // 掃除しに来るものは他に無いので、ここで落とし切る。
                // キャッシュは作り直せるので、フォルダが戻れば次の初回同期で復元される。
                let prefix = root.isEmpty ? "" : root.lowercased() + "/"
                let stale = await cache.cachedPaths(withPrefix: prefix)
                DropboxLogger.error("SyncEngine[\(root.isEmpty ? "/" : root)]: root is gone "
                    + "(path/not_found) — dropping \(stale.count) cached rows and stopping this root")
                if !stale.isEmpty {
                    await cache.applyDelta(accountId: scopeKey, added: [], removed: stale,
                                           newCursor: cursor)
                    onCacheUpdated(stale)
                }
                await cache.resetSyncCursor(accountId: scopeKey)
                reportState(.error("Folder not found: \(root.isEmpty ? "/" : root)"),
                            isPrimary: isPrimary)
                return false
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
        return false
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
            // ⚠️ **`media_info` はここでは返ってこない**（Dropbox 公式 SDK の記述・
            // 「This field will not be set on entries returned by list_folder,
            // list_folder_continue, or get_thumbnail_batch, **starting December 2, 2019**」）。
            // `include_media_info` を付けても無視されるので、**一覧から撮影日時・撮影地は取れない**。
            // 引数は害が無いので残す（将来仕様が戻ったときの意図表明）。
            // 撮影地を取っている唯一の経路は `DropboxPhotoStore+Location` の
            // `files/get_metadata`（1 枚ずつ・4〜6 秒）で、そちらは対象外なので今も効く。
            // 撮影日をどう取るかは未解決（`unresolved-problems.md`）。
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

        /// 差分カーソルの失効（Dropbox は 409 ＋ `error_summary: "reset/…"`）。
        /// ⚠️ これだけは**やり直しても無駄**なので、一時エラーと同じ扱いにしてはいけない。
        var isCursorReset: Bool {
            guard case .httpError(let status, let body) = self, status == 409 else { return false }
            return body.contains("reset")
        }

        /// 対象パスが存在しない（Dropbox は 409 ＋ `error_summary: "path/not_found/"`）。
        /// ⚠️ カーソル失効と同じく**やり直しても無駄**。同期ルートが消えた・共有が解除された
        /// ときにここへ来る（diagnostics-82）。
        var isPathNotFound: Bool {
            guard case .httpError(let status, let body) = self, status == 409 else { return false }
            return body.contains("not_found")
        }

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "Invalid server response."
            case .httpError(let code, _): return "HTTP \(code)"
            }
        }
    }
}
#endif
