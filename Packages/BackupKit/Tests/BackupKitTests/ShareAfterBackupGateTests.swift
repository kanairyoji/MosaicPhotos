import DropboxCore
import DropboxTestSupport
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// バックアップ後の反映は、待っていた共有写真があるときだけ（diagnostics-109）。
///
/// 実機では待ちが 0 枚の夜も、バックアップが終わるたびに全件の一覧を取り直す反映が
/// もう 1 回走っていた（夜間の手と合わせて毎窓 2 回・どちらも `copy=0 delete=0`）。
@Suite("共有の反映: バックアップ後の反映は待ちがあるときだけ", .serialized)
@MainActor
struct ShareAfterBackupGateTests {

    @Test("規則: 待ちが 1 枚でもあれば起こす／全部 0 なら起こさない／分からなければ起こす")
    func rule() {
        #expect(ShareAfterBackupGate.shouldSync(waitingBackup: [0, 0]) == false)
        #expect(ShareAfterBackupGate.shouldSync(waitingBackup: [0, 3]))
        #expect(ShareAfterBackupGate.shouldSync(waitingBackup: [0, nil]), "まだ数えていないセット")
        #expect(ShareAfterBackupGate.shouldSync(waitingBackup: nil), "読めない")
        #expect(ShareAfterBackupGate.shouldSync(waitingBackup: []) == false, "セットが無い")
    }

    private struct World {
        let engine: ShareSyncEngine
        let store: BackupStore
        let server: FakeDropboxServer
        let setID: UUID
    }

    /// 端末写真 2 枚のセット。`backedUp` の数だけバックアップ記録を作る（残りは「待ち」）。
    private func makeWorld(_ label: String, backedUp: Int) async -> World {
        let defaults = TestDefaults.scratch("share-after-backup-\(label)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set("/MosaicPhotos", forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for index in 0..<backedUp { await backUp(index, store: store, server: server) }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        let setID = await engine.createSet(name: "Family-\(label)", refKeys: ["L-p0", "L-p1"])!
        return World(engine: engine, store: store, server: server, setID: setID)
    }

    private func backUp(_ index: Int, store: BackupStore, server: FakeDropboxServer) async {
        let path = "/mosaicphotos/backup/2020/p\(index).jpg"
        await server.seed(path, hash: "h\(index)")
        await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(index)",
                                 filename: "p\(index).jpg", creationDate: nil, contentHash: "h\(index)",
                                 people: [], albums: [], isFavorite: false)
    }

    private func settle(_ engine: ShareSyncEngine) async {
        for _ in 0..<3 {
            for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
            await engine.syncNow()
        }
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// 材料の約束（実物）: 反映がセットごとに待ちを数えて控える／まだ数えていなければ nil。
    @Test("材料: 控えは反映が書く（数える前は nil・待ちは記録の無い写真の数）")
    func materialIsWrittenBySync() async {
        let world = await makeWorld("material", backedUp: 1)
        // createSet は反映を予約するので、走り終わる前に読むと nil か数えた値のどちらか。
        // 落ち着かせてから読む。
        await settle(world.engine)
        #expect(await world.store.shareWaitingBackupCounts() == [1], "記録の無い 1 枚が待ちに数えられていない")
        await backUp(1, store: world.store, server: world.server)
        await settle(world.engine)
        #expect(await world.store.shareWaitingBackupCounts() == [0], "上がったあとも待ちが残っている")

        // 数える前のセットは nil（0 に丸めない＝「分からない」を「待ちなし」と読まない）。
        let fresh = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        _ = await fresh.createShareSet(name: "unsynced", folderName: "unsynced")
        #expect(await fresh.shareWaitingBackupCounts() == [nil])
    }

    @Test("呼び出し側: 待ちが無ければ 1 往復もせず、見送ったことが残る")
    func noWaitingSkipsTheSync() async {
        let world = await makeWorld("skip", backedUp: 2)
        await settle(world.engine)
        #expect(await world.store.shareWaitingBackupCounts() == [0], "前提: 待ちが無い")
        let requestsBefore = await world.server.requestLog.count
        let tap = DiagnosticsLog.shared.tap()

        await world.engine.syncAfterBackup()

        #expect(await world.server.requestLog.count == requestsBefore, "待ちが無いのに反映した")
        #expect(await tap.count("share sync: バックアップ後の反映を見送る") == 1)
    }

    @Test("呼び出し側: 待ちがあれば反映し、上がった写真をコピーする")
    func waitingRunsTheSync() async {
        let world = await makeWorld("run", backedUp: 1)
        await settle(world.engine)
        #expect(await world.store.shareWaitingBackupCounts() == [1], "前提: 待ちが 1 枚")
        await backUp(1, store: world.store, server: world.server)   // バックアップが上げた
        let tap = DiagnosticsLog.shared.tap()

        await world.engine.syncAfterBackup()

        #expect(await tap.count("share sync: バックアップ後の反映を見送る") == 0)
        #expect(await world.store.shareSyncedCounts()[world.setID]?.present == 2, "上がった写真が共有されない")
        #expect(await world.store.shareWaitingBackupCounts() == [0])
    }
}
