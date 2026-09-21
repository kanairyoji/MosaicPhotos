import Foundation
import MosaicSupport
import Testing
@testable import DropboxCore

// MARK: - 期限の判定（純ロジック）

@Suite("クラウドの週次照合: 期限の判定")
struct CloudReconcilePolicyTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    /// ⚠️ **未完走（nil）は false**。「一度も全件を見ていない」の扱いは `syncOnce` が
    /// 既に持っている（カーソル・件数・完走の印で初回同期へ分岐する）。ここで true を
    /// 返すと判断が二重になり、どちらが効いているか読めなくなる。
    @Test("一度も完走していないなら、ここでは何も言わない")
    func neverScannedIsNotDue() {
        #expect(!CloudReconcilePolicy.isDue(lastFullScan: nil, now: now))
    }

    @Test("7 日経ったら期限、経っていなければまだ")
    func dueAfterAWeek() {
        #expect(!CloudReconcilePolicy.isDue(lastFullScan: now.addingTimeInterval(-week + 60), now: now))
        #expect(CloudReconcilePolicy.isDue(lastFullScan: now.addingTimeInterval(-week), now: now))
        #expect(CloudReconcilePolicy.isDue(lastFullScan: now.addingTimeInterval(-week * 3), now: now))
    }

    /// ⚠️ 時計が巻き戻ると「経過が負」になる。そこで見送ると**永久に照合されない**。
    @Test("時計が巻き戻ったら、間隔が空いたものとして扱う")
    func clockGoingBackwardsCountsAsDue() {
        #expect(CloudReconcilePolicy.isDue(lastFullScan: now.addingTimeInterval(week), now: now))
    }

    @Test("バックアップ台帳の照合と同じ 7 日")
    func matchesTheBackupInterval() {
        #expect(CloudReconcilePolicy.interval == week)
    }
}

#if canImport(UIKit)
import DropboxTestSupport

// MARK: - 取りこぼした削除が、週が明けたら掃除される

/// **差分だけが頼りの状態を、週 1 回の全件見直しが救えるか**（ADR-206）。
///
/// 差分（longpoll → `continue`）は「消えた」通知を一度でも取りこぼすと、その行が
/// 永久に残る——一覧には出るのに開けない写真になる（実機で確認＝diagnostics-82）。
/// バックアップ台帳には週 1 回の照合があるのに、クラウドのキャッシュには無かった。
///
/// ⚠️ `BackgroundYield.environmentOverrideForTesting` は**プロセス全体で 1 つ**。
/// 触るテストは同じ `.serialized` スイートに置くこと（swift-testing はスイートを
/// 既定で並列に走らせるので、`.serialized` だけでは別スイートとの取り合いを防げない）。
@Suite("クラウドの週次照合", .serialized)
@MainActor
struct CloudReconcileSyncTests {

    /// 見直しを終えたルートの数（`initialSyncCompletedAt` が基準より進んだもの）。
    private func rescannedCount(_ scopes: [String], in cache: DropboxCacheStore,
                                after baseline: Date) async -> Int {
        var count = 0
        for scope in scopes {
            if let last = await cache.syncStateInfo(accountId: scope)?.initialSyncCompletedAt,
               last > baseline { count += 1 }
        }
        return count
    }

    private func allRescanned(_ scopes: [String], in cache: DropboxCacheStore,
                              after baseline: Date) async -> Bool {
        await rescannedCount(scopes, in: cache, after: baseline) == scopes.count
    }

    /// `allSatisfy` の async 版（待ち条件をルートごとに書くため）。
    private func allComplete(_ scopes: [String], in cache: DropboxCacheStore) async -> Bool {
        for scope in scopes {
            guard await cache.syncStateInfo(accountId: scope)?.isInitialSyncCompleted == true
            else { return false }
        }
        return true
    }

    private let root = "/Photos"
    private let account = "acc"
    private var scope: String { account + "|" + root.lowercased() }

    @MainActor private final class Recorder {
        var states: [DropboxPhotoStore.SyncState] = []
    }

    private func makeEngine(_ server: FakeDropboxServer, cache: DropboxCacheStore,
                            recorder: Recorder) -> DropboxSyncEngine {
        DropboxSyncEngine(
            apiClient: DropboxAPIClient(httpClient: server, tokenProvider: FakeTokenProvider()),
            cache: cache, onCacheUpdated: { _ in },
            onStateChanged: { recorder.states.append($0) })
    }

    private func waitUntil(_ timeout: TimeInterval = 6,
                           _ condition: @MainActor () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func cachedPaths(_ cache: DropboxCacheStore) async -> [String] {
        await cache.cachedItems(accountId: account).map(\.path).sorted()
    }

    /// 取りこぼした削除を作る: サーバーからは消えるが、**変更ログには載らない**。
    private func seedThenLoseOneDeletion(_ server: FakeDropboxServer,
                                         cache: DropboxCacheStore,
                                         recorder: Recorder) async {
        await server.seed(root, hash: "", isFolder: true)
        for index in 0..<3 {
            await server.upload(path: "\(root)/p\(index).jpg", data: Data("photo-\(index)".utf8))
        }
        let engine = makeEngine(server, cache: cache, recorder: recorder)
        engine.start(accountId: account, roots: [root])
        // ⚠️ **件数で待たない**。写真はページごとに書かれるので、3 件そろった時点では
        // 初回同期はまだ Step 4（掃除と完走の印）に入っていない。そこで止めて
        // 「最後に全件を見た時刻」を書き換えても、走行中の初回同期が**後から上書きする**
        // ——期限切れを作ったつもりが作れておらず、テストが黙って素通りする。
        await waitUntil {
            await cache.syncStateInfo(accountId: self.scope)?.isInitialSyncCompleted == true
        }
        engine.stop()
        await server.removeSilently("\(root)/p1.jpg")
    }

    @Test("週が明けたら全件を見直して、消えていた写真を落とす")
    func weeklyReconcileDropsMissedDeletion() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }
        let server = FakeDropboxServer()
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = Recorder()
        await seedThenLoseOneDeletion(server, cache: cache, recorder: recorder)
        #expect(await cachedPaths(cache).count == 3, "前提: 取りこぼした行がまだ残っている")

        // 最後の全件走査を 8 日前にする＝期限切れ。
        await cache.markInitialSyncCompleted(accountId: scope,
                                             at: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        let engine = makeEngine(server, cache: cache, recorder: recorder)
        engine.start(accountId: account, roots: [root])
        await waitUntil { await self.cachedPaths(cache).count == 2 }
        engine.stop()

        let paths = await cachedPaths(cache)
        #expect(paths == ["\(root.lowercased())/p0.jpg", "\(root.lowercased())/p2.jpg"], """
                取りこぼした削除が残ったまま（\(paths)）。
                一覧には出るのに開けない写真になる（実機の「ファイルがありません」）。
                """)
        // ⚠️ 見直しの後は「最後に全件を見た時刻」が新しくなっていること
        //（進まないと毎回の起動で全件を引き直す）。
        let last = await cache.syncStateInfo(accountId: scope)?.initialSyncCompletedAt
        #expect(last.map { Date().timeIntervalSince($0) < 60 } == true,
                "全件を見直したのに、見た時刻が更新されていない")
    }

    /// ⚠️ **掃除したのが週次の見直しであること**を確かめる。期限内なら残るはず——
    /// 残らないなら、別の経路（差分・初回同期のやり直し）が消しているので、
    /// この機構が効いているかを上のテストでは判定できていない。
    @Test("期限内なら全件を引き直さない（掃除したのは見直しだと分かる）")
    func staysPutWhileWithinTheInterval() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }
        let server = FakeDropboxServer()
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = Recorder()
        await seedThenLoseOneDeletion(server, cache: cache, recorder: recorder)

        let engine = makeEngine(server, cache: cache, recorder: recorder)
        engine.start(accountId: account, roots: [root])
        try? await Task.sleep(for: .milliseconds(400))
        engine.stop()

        #expect(await cachedPaths(cache).count == 3,
                "期限が来ていないのに全件を引き直している（毎起動で 8 万件の一覧を引く）")
    }

    /// ⚠️ **見直しに失敗しても、動いていたポーリングを止めない**（レビュー 1 周目）。
    /// 週次の見直しは利用者が頼んだ処理ではなく、キャッシュは既に揃っている。
    /// 失敗で `syncLoop` を抜けると、**通信が一瞬切れただけでそのルートの同期が
    /// アプリを開き直すまで止まる**＝新しい写真が出てこなくなる。
    @Test("見直しに失敗しても、差分の追従は続く")
    func failedReconcileFallsBackToPolling() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }
        let server = FakeDropboxServer()
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = Recorder()
        await seedThenLoseOneDeletion(server, cache: cache, recorder: recorder)
        await cache.markInitialSyncCompleted(accountId: scope,
                                             at: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        // ⚠️ 仕込みは**見直しだけに当たるもの**を選ぶ。`files/list_folder` を指定すると
        // `list_folder/longpoll` にも当たり（`matches` は部分一致）、ポーリングごと
        // 落ちてしまう——「ポーリングが生きていること」を見たいのに前提を壊す。
        // 見直しの入口（ベースラインカーソルの取得）だけを落とす。
        await server.inject(.init(endpoint: "get_latest_cursor", effect: .status(500)))

        let engine = makeEngine(server, cache: cache, recorder: recorder)
        engine.start(accountId: account, roots: [root])
        // 見直しが失敗したあと、差分で拾える追加が届くこと＝ポーリングが生きている。
        try? await Task.sleep(for: .milliseconds(300))
        await server.upload(path: "\(root)/after-failure.jpg", data: Data("new".utf8))
        await waitUntil { await self.cachedPaths(cache).contains("\(root.lowercased())/after-failure.jpg") }
        engine.stop()

        let paths = await cachedPaths(cache)
        #expect(paths.contains("\(root.lowercased())/after-failure.jpg"), """
                見直しの失敗でポーリングごと止まっている（\(paths)）。
                通信が一瞬切れただけで、そのルートの同期がアプリを開き直すまで止まる。
                """)
        // ⚠️ 画面へエラーを出さない（利用者から見れば何も起きていない。しかも `.error` は
        // 共有の取り込みの掃除まで止める＝`cacheSettled`）。
        let reportedErrors = recorder.states.filter { if case .error = $0 { return true } else { return false } }
        #expect(reportedErrors.isEmpty, "頼んでもいない見直しの失敗を画面のエラーにした")
    }

    /// ⚠️ **ルートが揃って期限を迎えても、一斉には引かない**（レビュー 1 周目）。
    /// 実機のルートは 3 本（ソース・バックアップ・家族）で、**どれも同じ日に初回同期を
    /// 終えている**＝期限も同じ日に来る。素直に書くと 3 本が同じ窓で全件一覧を引き、
    /// 数分しかない窓で揃って中途半端に終わる——誰も印を進められないので、
    /// 次の窓でまた 3 本が一斉に始まる。
    @Test("複数のルートが同時に期限を迎えても、見直しは 1 本ずつ")
    func reconcilesOneRootAtATime() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .background)
        defer { BackgroundYield.environmentOverrideForTesting = nil }
        let server = FakeDropboxServer()
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = Recorder()
        let roots = ["/A", "/B"]
        for folder in roots {
            await server.seed(folder, hash: "", isFolder: true)
            await server.upload(path: "\(folder)/p.jpg", data: Data("photo".utf8))
        }
        let warmUp = makeEngine(server, cache: cache, recorder: recorder)
        warmUp.start(accountId: account, roots: roots)
        await waitUntil {
            await self.allComplete(roots.map { self.account + "|" + $0.lowercased() }, in: cache)
        }
        warmUp.stop()
        let stale = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        for folder in roots {
            await cache.markInitialSyncCompleted(accountId: account + "|" + folder.lowercased(),
                                                 at: stale)
        }
        // 応答を遅くして、1 本目が走っている「最中」を作る。
        // ⚠️ 数えるのは `callCounts()` ではなく `requestLog`。前者は**応答を返した後**に
        // 積むので、飛行中のリクエストが見えない——「同時に走っていないこと」を
        // 見たいのに、遅い応答ほど数えられなくなる（最初にこれで 0 件と出た）。
        await server.setResponseDelay(milliseconds: 500)
        let baseCursor = await server.requestLog.filter { $0.contains("get_latest_cursor") }.count
        let baseLongpoll = await server.requestLog.filter { $0.contains("longpoll") }.count

        let engine2 = makeEngine(server, cache: cache, recorder: recorder)
        engine2.start(accountId: account, roots: roots)
        // ⚠️ **時間で待たない**。「1 本目が見直しに入り、かつ 2 本目が判断を終えた」
        // ところまで待つ。longpoll は**ポーリングへ回ったルートしか投げない**ので、
        // それが 1 本出たことが「2 本目は見直しを見送った」の証拠になる。
        // 固定の待ちにすると、遅いマシンではどちらもまだ動いておらず 0 本＝偽の赤になる。
        await waitUntil {
            let cursors = await server.requestLog.filter { $0.contains("get_latest_cursor") }.count
            let polls = await server.requestLog.filter { $0.contains("longpoll") }.count
            return cursors > baseCursor && polls > baseLongpoll
        }
        let during = (await server.requestLog.filter { $0.contains("get_latest_cursor") }.count) - baseCursor

        #expect(during == 1, """
                1 本目の見直しの最中に \(during) 本が全件一覧を始めている。
                実機のルート 3 本は同じ日に期限を迎えるので、これは必ず起きる。
                """)

        // ⚠️ **「1 本ずつ」は「最初の 1 本だけ」ではない**（クラウドレビューの指摘）。
        // 確保を返し忘れると、2 本目以降はそのセッション中ずっと見直されない——
        // 重なりだけを見るテストでは、その状態も緑になる。
        // 1 本目が終わったあと、2 本目も順番が回ってくることまで見る。
        // ⚠️ 待つのは「一覧を始めた回数」ではなく**両方が見直しを終えたこと**
        //（始めただけで数えると、2 本目が走り出した瞬間に止めてしまう）。
        await server.setResponseDelay(milliseconds: 0)
        let scopes = roots.map { self.account + "|" + $0.lowercased() }
        await waitUntil(10) { await self.allRescanned(scopes, in: cache, after: stale) }
        let done = await rescannedCount(scopes, in: cache, after: stale)
        engine2.stop()

        #expect(done == scopes.count, """
                見直しを終えたのは \(done)/\(scopes.count) 本だけ。
                確保を返していないと、最初の 1 本以外はセッション中ずっと見直されない。
                """)
    }

    /// ⚠️ **前面では走らせない**（ADR-107）。8 万件の一覧は一枚岩の通信処理で、
    /// 始めたら譲れない。週に 1 度、画面を開いた瞬間に始まってよいものではない。
    @Test("前面では見直しを始めない")
    func doesNotReconcileInTheForeground() async {
        BackgroundYield.environmentOverrideForTesting = .init(scenePhase: .active)
        defer { BackgroundYield.environmentOverrideForTesting = nil }
        let server = FakeDropboxServer()
        let cache = DropboxCacheStore(isStoredInMemoryOnly: true)
        let recorder = Recorder()
        await seedThenLoseOneDeletion(server, cache: cache, recorder: recorder)
        await cache.markInitialSyncCompleted(accountId: scope,
                                             at: Date().addingTimeInterval(-8 * 24 * 60 * 60))

        let engine = makeEngine(server, cache: cache, recorder: recorder)
        engine.start(accountId: account, roots: [root])
        try? await Task.sleep(for: .milliseconds(400))
        engine.stop()

        #expect(await cachedPaths(cache).count == 3,
                "前面なのに全件の一覧を引き始めた（ADR-107: 一枚岩は前面で動かさない）")
    }
}
#endif
