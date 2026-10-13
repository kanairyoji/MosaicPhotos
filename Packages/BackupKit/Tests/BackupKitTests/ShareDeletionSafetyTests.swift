import DropboxCore
import DropboxTestSupport
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// **材料が欠けた回に、共有コピーを消さない**（ADR-278）。
///
/// ## 何が起きていたか
/// 差分の削除（ADR-209）は「実在 − 望ましい」で、望ましい集合の材料が**読めた**なら真実として使う。
/// ADR-277 で「読めなかった」は区別したが、**読めたのに中身が欠けている**回が残っていた:
/// - 台帳がこの起動だけインメモリに落ちた／壊れて作り直した → セットが 0 件に見え、
///   **全セットのフォルダ**を消しに行く。
/// - バックアップの実物が消え、照合が記録を消した → その写真の共有コピーを消す。オフロード済みなら
///   **それが最後の 1 枚**。
/// - クラウド写真の中身がまだ分からない回 → 別の名前になり、置き済みのコピーを消して別名でコピーし直す。
/// - 写真を編集した回に新しいコピーが失敗 → 古い版だけ消える。
///
/// ## ここで見ること
/// 落ち着いた共有に「欠け方」を 1 つずつ当て、その回に:
/// - **最後の 1 枚を消さない**（`FakeDropboxServer.deletedLastCopies == 0`——消した瞬間に数える）
/// - **家族から見える写真が減らない**（メンバーの中身がどれも共有フォルダに残る）
/// 利用者の操作（写真を外す・セットを消す）は逆向きに縛る: **家族からは消える**。中身が他に無ければ
/// `ShareRemoved` に残る。
///
/// ⚠️ 新しい「欠け方」を見つけたら `Gap` に 1 行足す。
@Suite("共有の反映: 材料が欠けた回に消さない（ADR-278）", .serialized)
@MainActor
struct ShareDeletionSafetyTests {

    private static let backupRoot = "/MosaicPhotos"
    private static let cloudPhoto = "/camera uploads/c1.jpg"
    private static func backupPath(_ index: Int) -> String { "/mosaicphotos/backup/2020/p\(index).jpg" }

    private struct World {
        let engine: ShareSyncEngine
        let store: BackupStore
        let server: FakeDropboxServer
        let defaults: UserDefaults
        let setID: UUID
        let setName: String
        var shareRoot: String { ShareSettingsKeys.currentShareRoot(defaults) }
        var holdingRoot: String { ShareSettingsKeys.currentShareRemovedRoot(defaults) }
        var setFolder: String {
            SharePlanning.setFolderPath(shareRoot: shareRoot, folderName: setName, deviceFolder: nil)!
        }
    }

    /// 端末写真 3 枚（バックアップ済み）＋クラウド写真 1 枚のセットを作り、落ち着くまで反映する。
    private func makeSettledWorld(_ label: String) async -> World {
        let defaults = TestDefaults.scratch("share-deletion-safety-\(label)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for index in 0..<3 {
            await server.seed(Self.backupPath(index), hash: "h\(index)")
            await store.upsertRecord(dropboxPath: Self.backupPath(index), localIdentifier: "p\(index)",
                                     filename: "p\(index).jpg", creationDate: nil, contentHash: "h\(index)",
                                     people: [], albums: [], isFavorite: false)
        }
        await server.seed(Self.cloudPhoto, hash: "hc")
        let engine = makeEngine(store: store, server: server, defaults: defaults)
        // ⚠️ 名前は**実行ごとに一意**にする。診断ログはプロセス（と Mac の Caches）で共有され、
        // 前の実行の行が残っているので、決まった名前だとログの検査が前の実行の行に当たって
        // 必ず通っていた（レビュー指摘）。
        let name = "Safety-\(label)-\(UUID().uuidString.prefix(8))"
        let setID = await engine.createSet(name: name,
                                           refKeys: ["L-p0", "L-p1", "L-p2", "C-\(Self.cloudPhoto)"])!
        for _ in 0..<3 { await quiesce(engine); await engine.syncNow() }
        await quiesce(engine)
        let folderName = await store.allShareSets().first { $0.id == setID }!.folderName
        return World(engine: engine, store: store, server: server, defaults: defaults,
                     setID: setID, setName: folderName)
    }

    private func makeEngine(store: BackupStore, server: FakeDropboxServer,
                            defaults: UserDefaults) -> ShareSyncEngine {
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.cloudSourceHashProvider = { [Self.cloudPhoto: "hc"] }
        return engine
    }

    private func quiesce(_ engine: ShareSyncEngine) async {
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private func sync(_ engine: ShareSyncEngine) async {
        await quiesce(engine)
        await engine.syncNow()
        await quiesce(engine)
    }

    /// 共有ルートの下の写真の中身（解析データを除く）。
    private func sharedHashes(_ world: World) async -> [String] {
        await hashes(under: world.shareRoot, world.server)
    }

    private func heldHashes(_ world: World) async -> [String] {
        await hashes(under: world.holdingRoot, world.server)
    }

    private func hashes(under root: String, _ server: FakeDropboxServer) async -> [String] {
        let prefix = root.lowercased() + "/"
        var out: [String] = []
        for path in await server.filePaths()
        where path.hasPrefix(prefix) && !path.contains("/\(ShareAnalysisData.subfolderName)/") {
            if let hash = await server.contentHash(at: path), !hash.isEmpty { out.append(hash) }
        }
        return out.sorted()
    }

    private func writes(_ server: FakeDropboxServer) async -> Int {
        await server.requestLog.filter {
            $0.contains("copy_batch") || $0.contains("delete_batch") || $0.contains("files/upload")
                || $0.contains("move_v2")
        }.count
    }

    /// 最後の 1 枚を消していない（落ちたら、どれを消したかを出す）。
    private func expectNoLastCopyDeleted(_ server: FakeDropboxServer,
                                         sourceLocation: SourceLocation = #_sourceLocation) async {
        let count = await server.deletedLastCopies
        let paths = await server.deletedLastCopyPaths
        #expect(count == 0, "最後の 1 枚を消した: \(paths)", sourceLocation: sourceLocation)
    }

    /// ⚠️ ログの検査は**この実行で書かれた行**だけを見る。名前を含まない断片は
    /// `logCount` で前後の数を比べる（並列の他のテスト・前の実行の行を数えない）。
    private func logged(_ fragment: String) async -> Bool {
        await logCount(fragment) > 0
    }

    private func logCount(_ fragment: String) async -> Int {
        await DiagnosticsLog.shared.recentLines(maxLines: 50_000).filter { $0.contains(fragment) }.count
    }

    /// 照合（`reconcileWithDropbox`）と同じ形で、Backup の実物が消えた写真の記録を消す。
    private func backupVanishes(_ index: Int, _ world: World) async {
        await world.server.remove(Self.backupPath(index))
        var remote: [String: String] = [:]
        for other in 0..<3 where other != index { remote[Self.backupPath(other)] = "h\(other)" }
        _ = await world.store.reconcile(remote: remote, listedAt: Date().addingTimeInterval(60))
        #expect(await world.store.backupRefs(forLocalIdentifiers: ["p\(index)"]).isEmpty,
                "前提: 記録が消えていない")
    }

    // MARK: - 欠け方の表

    enum Gap: String, CaseIterable, Sendable {
        /// 台帳がこの起動だけインメモリに落ちた（セットも記録も空に見える）。
        case ledgerFellBackToMemory
        /// 台帳が壊れて作り直された（永続だが空）。
        case ledgerRebuiltEmpty
        /// Backup の実物が消え、照合が記録を消した。
        case backupVanished
        /// クラウド写真の中身（content_hash）がまだ分からない。
        case cloudHashUnknown
        /// 写真を編集した（中身が変わった）回に、新しいコピーが失敗した。
        case editedButCopyFails
        /// 消す前の確認で、Dropbox に訊けなかった。
        case evidenceLookupFails
    }

    @Test("表が網羅している")
    func tableIsComplete() {
        #expect(Gap.allCases.count == 6)
    }

    @Test("欠けた回に、最後の 1 枚も、家族から見える写真も消さない", arguments: Gap.allCases)
    func gapDoesNotRemoveVisiblePhotos(_ gap: Gap) async {
        var world = await makeSettledWorld(gap.rawValue)
        let before = await sharedHashes(world)
        #expect(before == ["h0", "h1", "h2", "hc"], "前提: 共有が落ち着いていない \(before)")
        let writesBefore = await writes(world.server)
        let fallbackLinesBefore = await logCount("share sync: 台帳が一時的にインメモリで開いている")
        var engine = world.engine

        switch gap {
        case .ledgerFellBackToMemory:
            let store = BackupStore(modelContainer: BackupStore.memoryFallbackContainerForTesting())
            #expect(store.isTemporaryFallback, "前提: インメモリの代替として見えていない")
            engine = makeEngine(store: store, server: world.server, defaults: world.defaults)
        case .ledgerRebuiltEmpty:
            let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
            #expect(!store.isTemporaryFallback)
            engine = makeEngine(store: store, server: world.server, defaults: world.defaults)
        case .backupVanished:
            await backupVanishes(0, world)
        case .cloudHashUnknown:
            engine.cloudSourceHashProvider = { [:] }
        case .editedButCopyFails:
            await world.server.seed(Self.backupPath(1), hash: "h1v2")
            await world.store.upsertRecord(dropboxPath: Self.backupPath(1), localIdentifier: "p1",
                                           filename: "p1.jpg", creationDate: nil, contentHash: "h1v2",
                                           people: [], albums: [], isFavorite: false)
            let name = ShareNaming.sharedFileName(
                sourceFileName: "p1.jpg", identity: ShareNaming.identity(refKey: "L-p1", contentHash: "h1v2"))
            await world.server.setFailCopyPaths(["\(world.setFolder)/\(name)".lowercased()])
        case .evidenceLookupFails:
            // 利用者が外した写真（中身は Backup に在る）を、訊けない回に消すか。
            _ = await world.engine.removeItems(setID: world.setID, refKeys: ["L-p2"])
            await quiesce(world.engine)
            await world.server.inject(.init(endpoint: "get_metadata", times: 100, effect: .status(503)))
        }
        world = World(engine: engine, store: world.store, server: world.server,
                      defaults: world.defaults, setID: world.setID, setName: world.setName)

        await sync(engine)

        await expectNoLastCopyDeleted(world.server)
        let after = await sharedHashes(world)
        switch gap {
        case .ledgerFellBackToMemory:
            #expect(await writes(world.server) == writesBefore, "一時的な台帳で書き込んだ")
            #expect(engine.lastError == .ledgerUnavailable)
            #expect(await logCount("share sync: 台帳が一時的にインメモリで開いている") > fallbackLinesBefore)
            #expect(after == before)
        case .ledgerRebuiltEmpty:
            #expect(after == before, "空の台帳を真実として共有フォルダを消した")
            let named = await DiagnosticsLog.shared.recentLines(maxLines: 50_000).contains {
                $0.contains("share sync: 持ち主の分からないフォルダ") && $0.contains(world.setName.lowercased())
            }
            #expect(named, "持ち主の分からないフォルダの行（フォルダ名つき）が無い")
        case .backupVanished:
            #expect(after == before, "記録が消えた写真の共有コピーを消した")
            #expect(await logged("share: '\(world.setName)' 消す前の確認で残した"))
        case .cloudHashUnknown:
            #expect(await writes(world.server) == writesBefore,
                    "中身が分からない回に、別名でコピーし直した／消した")
            #expect(after == before)
        case .editedButCopyFails:
            #expect(after == before, "新しい版のコピーが失敗した回に、古い版を消した")
        case .evidenceLookupFails:
            #expect(after == ["h0", "h1", "h2", "hc"], "確かめきれないのに消した（または退避した）")
            // ⚠️ 確かめに行ったことも見る（確かめずに残しても上の 2 行は通る・レビュー指摘）。
            // 失敗を仕込んだ要求は `requestLog` に載らないので、仕込みを踏んだかで見る。
            #expect(await world.server.pendingFaults().first?.times ?? 100 < 100,
                    "Dropbox に訊いていない（確かめる手順が走っていない）")
            #expect(await logged("share: '\(world.setName)' 消す前の確認で残した 1 枚（メンバーのコピー 0・確かめきれない 1"))
            #expect(await heldHashes(world).isEmpty, "確かめきれないのに退避した")
        }

        // 健全に戻せば収束する（見送っただけで、詰まっていない）。
        await world.server.clearFaults()
        await world.server.setFailCopyPaths([])
        world.engine.cloudSourceHashProvider = { [Self.cloudPhoto: "hc"] }
        for _ in 0..<3 { await sync(world.engine) }
        await expectNoLastCopyDeleted(world.server)
        switch gap {
        case .editedButCopyFails:
            // 新しい版が届き、古い版（中身はもうどこにも無い）は退避される。
            #expect(await sharedHashes(world) == ["h0", "h1v2", "h2", "hc"])
            #expect(await heldHashes(world) == ["h1"], "古い版を消した（退避していない）")
        case .evidenceLookupFails:
            #expect(await sharedHashes(world) == ["h0", "h1", "hc"], "外した写真が家族から消えない")
            #expect(await heldHashes(world).isEmpty, "Backup に在る写真まで退避した")
        default:
            #expect(await sharedHashes(world) == before)
        }
    }

    // MARK: - 利用者の操作（逆向き: 家族からは消える）

    @Test("外した写真は家族から消える。Backup に在れば退避しない")
    func removedPhotoWithBackupIsDeleted() async {
        let world = await makeSettledWorld("remove-with-backup")
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["L-p2"])
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h0", "h1", "hc"])
        #expect(await heldHashes(world).isEmpty)
        await expectNoLastCopyDeleted(world.server)
    }

    @Test("外した写真の中身がどこにも無ければ、家族からは消して ShareRemoved に残す")
    func removedPhotoWithoutBackupIsHeld() async {
        let world = await makeSettledWorld("remove-without-backup")
        await backupVanishes(0, world)
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["L-p0"])
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h1", "h2", "hc"], "外した写真が家族から消えない")
        #expect(await heldHashes(world) == ["h0"], "最後の 1 枚を退避していない")
        await expectNoLastCopyDeleted(world.server)
        #expect(await logged("share: '\(world.setName)' 中身が Dropbox のどこにも無い 1 枚を"))
        // 次の回にもう一度動かない（退避先は差分の対象ではない）。
        let writesBefore = await writes(world.server)
        await sync(world.engine)
        #expect(await writes(world.server) == writesBefore)
    }

    @Test("セットを消すとフォルダごと消える。中身がどこにも無い写真だけ退避する")
    func deletedSetIsRemovedButLastCopiesAreHeld() async {
        let world = await makeSettledWorld("delete-set")
        await backupVanishes(1, world)
        _ = await world.engine.deleteSet(id: world.setID)
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty, "消したセットのフォルダが残っている")
        #expect(await heldHashes(world) == ["h1"])
        await expectNoLastCopyDeleted(world.server)
        #expect(ShareSettingsKeys.retiredFolders(world.defaults).keys.contains(world.setFolder.lowercased()),
                "猶予のあいだは印を持っておく（遅れて完走したコピーを片付けるため）")
    }

    @Test("消す前の確認で記録が読めない回は、消しも退避もしない（「無い」と読まない）")
    func unreadableRecordsDuringReviewLeaveEverything() async {
        let world = await makeSettledWorld("review-records-unreadable")
        _ = await world.engine.deleteSet(id: world.setID)
        await quiesce(world.engine)
        await world.store.setFailingShareReadForTesting(.backupRecords)
        let writesBefore = await writes(world.server)
        let unreadableBefore = await logCount("share: 消す前の確認でバックアップ記録が読めない")
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"],
                "記録が読めないのに、消したセットの写真を片付けた")
        #expect(await heldHashes(world).isEmpty, "記録が読めないのを「どこにも無い」と読んで退避した")
        #expect(await writes(world.server) == writesBefore)
        #expect(await logCount("share: 消す前の確認でバックアップ記録が読めない") > unreadableBefore)
        await world.store.setFailingShareReadForTesting(nil)
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty)
        #expect(await heldHashes(world).isEmpty)
        await expectNoLastCopyDeleted(world.server)
    }

    @Test("消したフォルダが遅れて作り直されても、印があるので片付く")
    func resurrectedRetiredFolderIsSwept() async {
        let world = await makeSettledWorld("resurrected")
        _ = await world.engine.deleteSet(id: world.setID)
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty)
        // 発行済みのコピーが遅れて完走した形。
        await world.server.seed("\(world.setFolder)/late.jpg", hash: "h0")
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty, "遅れて作り直されたフォルダが残っている")
        await expectNoLastCopyDeleted(world.server)
    }

    @Test("外したクラウド写真は、原本が在れば消える（退避しない）")
    func removedCloudPhotoIsDeleted() async {
        let world = await makeSettledWorld("remove-cloud")
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["C-\(Self.cloudPhoto)"])
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h0", "h1", "h2"], "外したクラウド写真が家族から消えない")
        #expect(await heldHashes(world).isEmpty, "原本が在るのに退避した（中身の行き先を引けていない）")
        await expectNoLastCopyDeleted(world.server)
    }

    @Test("同期一覧が空の回は、外したクラウド写真を退避しない（分からない）")
    func emptyCloudIndexDoesNotHold() async {
        let world = await makeSettledWorld("remove-cloud-cold")
        world.engine.cloudSourceHashProvider = { [:] }
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["C-\(Self.cloudPhoto)"])
        await sync(world.engine)
        #expect(await heldHashes(world).isEmpty, "一覧がまだ無いだけなのに、どこにも無いと読んで退避した")
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"])
        world.engine.cloudSourceHashProvider = { [Self.cloudPhoto: "hc"] }
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h0", "h1", "h2"])
        #expect(await heldHashes(world).isEmpty)
    }

    @Test("同期一覧に無いクラウド写真の中身は Dropbox に訊いてコピーする")
    func missingCloudHashIsLookedUp() async {
        let world = await makeSettledWorld("cloud-lookup")
        await world.server.seed("/elsewhere/new.jpg", hash: "hn")
        _ = await world.engine.addItems(setID: world.setID, refKeys: ["C-/elsewhere/new.jpg"])
        await sync(world.engine)
        #expect(await sharedHashes(world).contains("hn"), "同期一覧に無いクラウド写真が永久に待つ")
    }

    @Test("上限で打ち切った一覧は「取れなかった」扱い（部分の一覧で消さない）")
    func truncatedListingIsUnavailable() async {
        let server = FakeDropboxServer()
        for index in 0..<201 { await server.seed("/big/f\(index).jpg", hash: "h\(index)") }
        await server.setPageSize(1)
        let copier = DropboxShareCopier(httpClient: server)
        #expect(await copier.listFolder(path: "/big", token: "t") == nil,
                "200 ページで打ち切った一覧を完全な一覧として返した")
        await server.setPageSize(500)
        #expect(await copier.listFolder(path: "/big", token: "t")?.count == 201)
    }

    @Test("確かめている間に写真を入れ直したら、その回は消さない")
    func memberReAddedDuringReviewIsNotRemoved() async {
        let world = await makeSettledWorld("readd-mid-run")
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["L-p2"])
        await quiesce(world.engine)
        let store = world.store
        let setID = world.setID
        world.engine.beforeRemovalWritesForTesting = {
            _ = await store.addShareItems(setID: setID, refKeys: ["L-p2"])
        }
        await world.engine.syncNow()
        await quiesce(world.engine)
        world.engine.beforeRemovalWritesForTesting = nil
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"], "入れ直した写真のコピーを消した")
        #expect(await logged("share: '\(world.setName)' 反映の途中でセットかメンバーが変わった"))
        await sync(world.engine)
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"])
    }

    @Test("確かめている間に、中身がどこにも無い写真を入れ直したら、退避しない")
    func memberReAddedDuringReviewIsNotHeld() async {
        let world = await makeSettledWorld("readd-held")
        await backupVanishes(2, world)
        _ = await world.engine.removeItems(setID: world.setID, refKeys: ["L-p2"])
        await quiesce(world.engine)
        let store = world.store
        let setID = world.setID
        world.engine.beforeRemovalWritesForTesting = {
            _ = await store.addShareItems(setID: setID, refKeys: ["L-p2"])
        }
        await world.engine.syncNow()
        await quiesce(world.engine)
        world.engine.beforeRemovalWritesForTesting = nil
        #expect(await heldHashes(world).isEmpty, "入れ直した写真を退避した（家族から消えた）")
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"])
    }

    @Test("確かめている間に同じ名前でセットを作り直したら、そのフォルダは消さない")
    func setRecreatedDuringSweepIsNotRemoved() async {
        let world = await makeSettledWorld("recreate-mid-sweep")
        _ = await world.engine.deleteSet(id: world.setID)
        await quiesce(world.engine)
        let engine = world.engine
        let name = world.setName
        var recreated = false
        engine.beforeRemovalWritesForTesting = {
            guard !recreated else { return }
            recreated = true
            engine.beforeRemovalWritesForTesting = nil
            _ = await engine.createSet(name: name, refKeys: ["L-p0", "L-p1", "L-p2", "C-\(Self.cloudPhoto)"])
        }
        let deletesBefore = await world.server.requestLog.filter { $0.contains("delete_batch") }.count
        await engine.syncNow()
        await quiesce(engine)
        #expect(recreated, "前提: 掃除の確認の途中で作り直していない")
        await sync(engine)
        // ⚠️ 終わりの状態では見えない（消しても次の回にコピーし直す）ので、**消しに行ったか**を数える。
        let deletesAfter = await world.server.requestLog.filter { $0.contains("delete_batch") }.count
        #expect(deletesAfter == deletesBefore, "作り直したセットのフォルダを消しに行った")
        #expect(await sharedHashes(world) == ["h0", "h1", "h2", "hc"])
        await expectNoLastCopyDeleted(world.server)
    }

    @Test("フォルダごと消す前に一覧を取り直し、確かめていないファイルが在れば消さない")
    func lateArrivalBlocksWholeFolderDelete() async {
        let world = await makeSettledWorld("late-arrival")
        let server = world.server
        let folder = world.setFolder
        world.engine.beforeRemovalWritesForTesting = {
            // 確かめ終えた後に、家族が写真を 1 枚置いた（中身はどこにも無い）。
            await server.seed("\(folder)/from-family.jpg", hash: "hFamily")
            await server.seed("\(folder)/\(ShareAnalysisData.subfolderName)/notes.txt", hash: "hNotes")
        }
        _ = await world.engine.deleteSet(id: world.setID)
        await sync(world.engine)
        world.engine.beforeRemovalWritesForTesting = nil
        let paths = await server.filePaths()
        // 次の回で確かめられて退避されるのは正しい（中身はどこにも無い）。消えていないことを見る。
        #expect(paths.contains { $0.hasSuffix("/from-family.jpg") }, "確かめていない写真をフォルダごと消した")
        #expect(paths.contains("\(folder.lowercased())/\(ShareAnalysisData.subfolderName)/notes.txt"))
        await expectNoLastCopyDeleted(server)
    }

    @Test("消したフォルダの印は、フォルダを最後に見た時刻から 24 時間持つ")
    func retiredMarkGraceCountsFromLastSeen() async {
        let world = await makeSettledWorld("grace")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        world.engine.removalClock = { clock }
        await backupVanishes(1, world)   // 1 枚は退避になる
        await world.server.setFailMove(true)   // 退避できない＝フォルダは何日も残る
        _ = await world.engine.deleteSet(id: world.setID)
        await sync(world.engine)
        let key = world.setFolder.lowercased()
        #expect(ShareSettingsKeys.retiredFolders(world.defaults)[key] != nil)
        // 消してから 30 時間、フォルダはまだ在る（退避が失敗し続けている）。
        clock = clock.addingTimeInterval(30 * 3_600)
        await sync(world.engine)
        #expect(ShareSettingsKeys.retiredFolders(world.defaults)[key] == clock,
                "フォルダが在るのに、最後に見た時刻へ進めていない")
        // 退避できるようになり、フォルダが片付く。直後の回では印を捨てない。
        await world.server.setFailMove(false)
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty)
        clock = clock.addingTimeInterval(3_600)
        await sync(world.engine)
        #expect(ShareSettingsKeys.retiredFolders(world.defaults)[key] != nil,
                "フォルダが消えた直後に印を捨てた（消した時刻から数えている）")
        // 遅れて完走したコピーが作り直しても片付く。
        await world.server.seed("\(world.setFolder)/late.jpg", hash: "h0")
        await sync(world.engine)
        #expect(await sharedHashes(world).isEmpty)
        // 最後に見てから 24 時間を過ぎたら捨てる。
        clock = clock.addingTimeInterval(25 * 3_600)
        await sync(world.engine)
        #expect(ShareSettingsKeys.retiredFolders(world.defaults)[key] == nil, "印を捨てない")
    }

    @Test("最後の 1 枚の数え方（偽 Dropbox）")
    func fakeCountsLastCopies() async {
        let server = FakeDropboxServer()
        await server.seed("/a/x.jpg", hash: "hx")
        await server.seed("/b/x.jpg", hash: "hx")
        await server.seed("/c/y.jpg", hash: "hy")
        let copier = DropboxShareCopier(httpClient: server)
        _ = await copier.deleteBatch(paths: ["/a/x.jpg"], token: "t")
        #expect(await server.deletedLastCopies == 0, "もう 1 枚残っているのに数えた")
        _ = await copier.deleteBatch(paths: ["/b"], token: "t")
        #expect(await server.deletedLastCopies == 1, "フォルダごとの削除の中身を数えていない")
        _ = await copier.deleteBatch(paths: ["/c/y.jpg"], token: "t")
        #expect(await server.deletedLastCopies == 2)
    }
}
