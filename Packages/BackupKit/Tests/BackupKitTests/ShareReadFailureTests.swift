import DropboxCore
import DropboxTestSupport
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// **読めなかった回は、何も書かない**（ADR-277・実機ログ diagnostics-108）。
///
/// ## 何が起きたか
/// 停止からの復帰直後に共有ルートの一覧（`list_folder`）だけが失敗した。反映は
/// 「一覧が取れない → ルートがまだ無い → 作れた（実は 409＝既にある）→ **空**」と読み、
/// 置き済みの 21,191 枚を全部「未コピー」と判断して 500 件のコピーを投げ、
/// 「共有済み」を 0 に書き換えた。計画（`SharePlanning.plan`）には「一覧が無ければ何も決めない」
/// という守りがあったのに、手前で失敗が**空の一覧に化けて**効いていなかった。
///
/// ## なぜ既存のテストで出なかったか
/// - 不変条件のテスト（`ShareInvariantTests`）の操作列には `listFailure` が**入っていた**。
///   ただし検査は**終わりの状態**だけで、この誤りは衝突で全部失敗して次の回に自然に直るので
///   終わりの状態には残らない。
/// - `DropboxShareCopier` のテストは「409 は成功扱い」を**望ましい性質として固定**していた
///   （ADR-258 で「毎起動 1 回作り直す」を固定していたのと同じ形）。
///
/// ## ここで見ること（表で総当たり）
/// 落ち着いた共有に対して「読む」ものを 1 つずつ壊し、**その回の振る舞い**を見る:
/// - 書き込み（コピー・削除・アップロード）が 0
/// - 既に在る宛先へのコピー（衝突）が 0
/// - 画面に出す「共有済み」の数が変わらない
/// - 失敗が見える（`lastError`）——黙って何もしないにしない
/// - 仕込んだ失敗を**実際に踏んだ**（`pendingFaults` が空）——踏んでいなければ何も確かめていない
/// 直したあとに健全な回で元どおりになることも見る。
///
/// ⚠️ 新しく「読む」ものを足したら、この表に 1 行足す。壊し方が増えたら `effects` に足す。
@Suite("共有の反映: 読めなかった回は何も書かない（障害注入の総当たり）", .serialized)
@MainActor
struct ShareReadFailureTests {

    private static let backupRoot = "/MosaicPhotos"
    private static let cloudPhoto = "/camera uploads/c1.jpg"

    private struct World {
        let engine: ShareSyncEngine
        let store: BackupStore
        let server: FakeDropboxServer
        let setID: UUID
        let shareRoot: String
    }

    /// 端末写真 3 枚（バックアップ済み）＋クラウド写真 1 枚のセットを作り、落ち着くまで反映する。
    ///
    /// ⚠️ **クラウド写真を混ぜるのが要点**。端末写真だけだと、記録が読めない回は
    /// 「望ましい集合が空なのにメンバーは居る」で計画の安全弁が止めてしまい、
    /// 記録の読みを空に潰す実装と正しい実装を**区別できない**（fixture が 2 つの結果を分けない）。
    private func makeSettledWorld(_ label: String) async -> World {
        let defaults = TestDefaults.scratch("share-read-failure-\(label)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for index in 0..<3 {
            let path = "/mosaicphotos/backup/2020/p\(index).jpg"
            await server.seed(path, hash: "h\(index)")
            await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(index)",
                                     filename: "p\(index).jpg", creationDate: nil, contentHash: "h\(index)",
                                     people: [], albums: [], isFavorite: false)
        }
        await server.seed(Self.cloudPhoto, hash: "hc")
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.cloudSourceHashProvider = { [Self.cloudPhoto: "hc"] }
        let setID = await engine.createSet(name: "Family-\(label)",
                                           refKeys: ["L-p0", "L-p1", "L-p2", "C-\(Self.cloudPhoto)"])!
        // ⚠️ 2 ページに分かれるようにする（2 ページ目＝`list_folder/continue` の失敗も踏めるように）。
        await server.setPageSize(2)
        for _ in 0..<3 { await quiesce(engine); await engine.syncNow() }
        await quiesce(engine)
        return World(engine: engine, store: store, server: server, setID: setID,
                     shareRoot: ShareSettingsKeys.currentShareRoot(defaults))
    }

    private func quiesce(_ engine: ShareSyncEngine) async {
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private func writes(_ server: FakeDropboxServer) async -> Int {
        await server.requestLog.filter {
            $0.contains("copy_batch") || $0.contains("delete_batch") || $0.contains("files/upload")
        }.count
    }

    /// 共有フォルダにある写真（解析データを除く）の中身。
    private func sharedHashes(_ world: World) async -> [String] {
        let prefix = world.shareRoot.lowercased() + "/"
        var out: [String] = []
        for path in await world.server.filePaths()
        where path.hasPrefix(prefix) && !path.contains("/\(ShareAnalysisData.subfolderName)/") {
            if let hash = await world.server.contentHash(at: path), !hash.isEmpty { out.append(hash) }
        }
        return out.sorted()
    }

    // MARK: - 壊し方の表

    /// どの「読み」を壊すか。
    enum Read: String, CaseIterable, Sendable {
        case firstPage      // 共有ルートの一覧（1 ページ目）
        case nextPage       // 共有ルートの一覧（2 ページ目以降）
        case members        // セットのメンバー（SwiftData）
        case backupRecords  // バックアップ記録（SwiftData）
    }

    /// 通信の壊し方。SwiftData の読み（members / backupRecords）には使わない。
    static let effects: [FakeDropboxServer.Effect] = [
        .status(503), .status(429, retryAfter: 1), .networkError, .truncateBody,
    ]

    struct Case: CustomTestStringConvertible, Sendable {
        let read: Read
        let effect: FakeDropboxServer.Effect?
        var testDescription: String { "\(read.rawValue) × \(effect.map { "\($0)" } ?? "fetch failure")" }
    }

    static let cases: [Case] = Read.allCases.flatMap { read -> [Case] in
        switch read {
        case .firstPage, .nextPage: return effects.map { Case(read: read, effect: $0) }
        case .members, .backupRecords: return [Case(read: read, effect: nil)]
        }
    }

    @Test("表が網羅している（読み × 壊し方の通り数・空振りしない）")
    func tableIsComplete() {
        // ⚠️ 組み合わせを作る側が壊れたら、下の総当たりは**静かに空振り**する（ADR-271）。
        #expect(Self.cases.count == 2 * Self.effects.count + 2)
        for read in Read.allCases {
            #expect(Self.cases.contains { $0.read == read }, "\(read) が表に無い")
        }
    }

    @Test("読めなかった回は書かず、数も変えず、失敗が見える", arguments: cases)
    func failedReadWritesNothing(_ testCase: Case) async {
        let world = await makeSettledWorld("\(testCase.read.rawValue)-\(String(describing: testCase.effect))")

        // 前提: 落ち着いている（4 枚とも在る・数も 4・エラーなし）。前提が崩れていたら何も確かめていない。
        let before = await sharedHashes(world)
        #expect(before == ["h0", "h1", "h2", "hc"], "前提: 共有が落ち着いていない \(before)")
        #expect(await world.store.shareSyncedCounts()[world.setID]?.present == 4)
        #expect(world.engine.lastError == nil)
        let writesBefore = await writes(world.server)
        let conflictsBefore = await world.server.conflictedCopyEntries

        switch testCase.read {
        case .firstPage:
            // ⚠️ `files/list_folder` は `list_folder/continue` にも当たるので、1 回だけにする
            // （最初の 1 回＝1 ページ目）。
            await world.server.inject(.init(endpoint: "files/list_folder", times: 1, effect: testCase.effect!))
        case .nextPage:
            await world.server.inject(.init(endpoint: "list_folder/continue", times: 1, effect: testCase.effect!))
        case .members:
            await world.store.setFailingShareReadForTesting(.members)
        case .backupRecords:
            await world.store.setFailingShareReadForTesting(.backupRecords)
        }

        await world.engine.syncNow()
        await quiesce(world.engine)

        // 仕込んだ失敗を踏んだか（踏んでいなければ、この先の assert は何も確かめていない）。
        #expect(await world.server.pendingFaults().isEmpty, "仕込んだ失敗が使われていない")
        // ⚠️ 見送ったことも名指しで確かめる（「別の仕組みで通っている」を隠さない・ADR-274 追補 2）。
        // 診断ログは並列のテストも書くので、セット名（テストごとに一意）で探す。
        let lines = await DiagnosticsLog.shared.recentLines(maxLines: 50_000)
        let setName = await world.store.allShareSets().first?.name ?? "?"
        switch testCase.read {
        case .firstPage, .nextPage:
            #expect(lines.contains { $0.contains("share sync: 共有ルートの一覧が取れない") })
        case .members:
            #expect(lines.contains { $0.contains("'\(setName)' のメンバーが読めない") },
                    "メンバーの読み失敗で見送っていない（別の守りで通っている）")
        case .backupRecords:
            #expect(lines.contains { $0.contains("'\(setName)' のバックアップ記録が読めない") },
                    "記録の読み失敗で見送っていない（別の守りで通っている）")
        }
        #expect(await writes(world.server) == writesBefore, "読めなかった回に書き込んだ")
        #expect(await world.server.conflictedCopyEntries == conflictsBefore,
                "既に在る宛先へコピーを投げた（一覧の失敗を空と読んでいる）")
        #expect(await sharedHashes(world) == before, "共有フォルダの中身が変わった")
        #expect(await world.store.shareSyncedCounts()[world.setID]?.present == 4,
                "「共有済み」の数を書き換えた（実在が分からない回に）")
        switch testCase.read {
        case .firstPage, .nextPage:
            // ⚠️ 黙って何もしないにしない（実機で「詰まっているのにログが無い」を何度も踏んだ）。
            #expect(world.engine.lastError != nil, "一覧の失敗が見えない")
        case .members, .backupRecords:
            break   // セット単位で見送る（診断ログに残す）。画面の赤字にはしない
        }

        // 健全に戻せば、何も書かずに元どおり（＝見送っただけで、壊していない）。
        await world.server.clearFaults()
        await world.store.setFailingShareReadForTesting(nil)
        await world.engine.syncNow()
        await quiesce(world.engine)
        #expect(world.engine.lastError == nil)
        #expect(await writes(world.server) == writesBefore, "落ち着いた共有に書き込んだ")
        #expect(await world.store.shareSyncedCounts()[world.setID]?.present == 4)
    }

    @Test("初回（共有ルートがまだ無い）は、作ってからコピーする（「作った」だけが空を意味する）")
    func firstRunCreatesRootAndCopies() async {
        // ⚠️ 逆向きも縛る（ADR-256）。「一覧が取れなければ何もしない」にすると、
        // 初回の共有が永久に始まらない。「作った」と「既にあった」を分けたのはこのため。
        let defaults = TestDefaults.scratch("share-read-failure-first-run")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        await server.seed("/mosaicphotos/backup/2020/p0.jpg", hash: "h0")
        await store.upsertRecord(dropboxPath: "/mosaicphotos/backup/2020/p0.jpg", localIdentifier: "p0",
                                 filename: "p0.jpg", creationDate: nil, contentHash: "h0",
                                 people: [], albums: [], isFavorite: false)
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        let setID = await engine.createSet(name: "First", refKeys: ["L-p0"])!
        await quiesce(engine)
        await engine.syncNow()
        await quiesce(engine)
        #expect(engine.lastError == nil)
        #expect(await store.shareSyncedCounts()[setID]?.present == 1, "初回の共有が始まらない")
        #expect(await server.conflictedCopyEntries == 0)
    }
}
