import DropboxCore
import DropboxTestSupport
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// 共有の反映を起こす入口は `ShareSyncEngine.sync(_:)` の 1 つ。起こし方ごとの決まりは 1 つの表。
///
/// 以前は呼ぶ側 4 か所が回線・セットの有無・作成元への追従をそれぞれ判断しており、
/// diagnostics-109 の「毎窓 2 回」はその形から出た。
@Suite("共有の反映: 起こし方ごとの決まり", .serialized)
@MainActor
struct ShareSyncTriggerTests {

    @Test("表: 自動で起こすものだけ回線とセットの有無を見る／夜間と手動は同じ決まり")
    func ruleTable() {
        #expect(ShareSyncTrigger.allCases.count == 5, "起こし方を足したら、このテストの期待も足す")
        let network = ShareSyncTrigger.allCases.filter(\.rule.respectsNetworkPolicy)
        #expect(network == [.launch, .afterBackup])
        let sets = ShareSyncTrigger.allCases.filter(\.rule.requiresAnySet)
        #expect(sets == [.launch, .afterBackup])
        let follows = ShareSyncTrigger.allCases.filter(\.rule.followsSource)
        #expect(follows == [.nightly, .manual])
        let waiting = ShareSyncTrigger.allCases.filter(\.rule.requiresWaitingBackup)
        #expect(waiting == [.afterBackup])
        #expect(ShareSyncTrigger.nightly.rule == ShareSyncTrigger.manual.rule,
                "「押せば夜間と同じことが今すぐ起きる」")
    }

    final class Resolver: ShareSourceResolver {
        var calls = 0
        func currentMembers(for key: ShareSourceKey) async -> [String]? {
            calls += 1
            return ["L-p0"]
        }
    }

    private struct World {
        let engine: ShareSyncEngine
        let server: FakeDropboxServer
        let resolver: Resolver
    }

    /// 端末写真 1 枚（バックアップ済み）＋待ちの 1 枚。`withSet` なら作成元つきのセットを 1 つ作って落ち着かせる。
    private func makeWorld(_ label: String, withSet: Bool, network: Bool) async -> World {
        let defaults = TestDefaults.scratch("share-trigger-\(label)")
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set("/MosaicPhotos", forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        let path = "/mosaicphotos/backup/2020/p0.jpg"
        await server.seed(path, hash: "h0")
        await store.upsertRecord(dropboxPath: path, localIdentifier: "p0",
                                 filename: "p0.jpg", creationDate: nil, contentHash: "h0",
                                 people: [], albums: [], isFavorite: false)
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.networkAllowed = { network }
        let resolver = Resolver()
        engine.sourceResolver = resolver
        if withSet {
            // ⚠️ p1 はバックアップしていない＝待ちが 1 枚。待ちが 0 だとバックアップ後の起こし方は
            // ゲートが先に止めるので、回線の確認を外しても区別できない（fixture が結果を分けない）。
            _ = await engine.createSet(name: "Family-\(label)", refKeys: ["L-p0", "L-p1"],
                                       sourceKey: ShareSourceKey.person(1).encoded)
            for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
            await engine.syncNow()
        }
        resolver.calls = 0
        return World(engine: engine, server: server, resolver: resolver)
    }

    @Test("回線ポリシーを満たさないとき: 自動の起こし方は 1 往復もしない／手動・夜間は走る",
          arguments: ShareSyncTrigger.allCases)
    func networkPolicy(trigger: ShareSyncTrigger) async {
        let world = await makeWorld("net-\(trigger.rawValue)", withSet: true, network: false)
        let before = await world.server.requestLog.count
        await world.engine.sync(trigger)
        let made = await world.server.requestLog.count - before
        if trigger.rule.respectsNetworkPolicy {
            #expect(made == 0, "回線ポリシーを無視して反映した")
        } else {
            // ⚠️ 逆向きも縛る（全部止めても通る形にしない）。
            #expect(made > 0, "回線ポリシーを見ない起こし方まで止めた")
        }
    }

    @Test("セットが無いとき: 起動・バックアップ後は 1 往復もしない")
    func noSets() async {
        for trigger in [ShareSyncTrigger.launch, .afterBackup] {
            let world = await makeWorld("nosets-\(trigger.rawValue)", withSet: false, network: true)
            await world.engine.sync(trigger)
            #expect(await world.server.requestLog.isEmpty, "\(trigger): セットが無いのに通信した")
        }
        // ⚠️ fixture が 2 つの結果を区別できること: 同じ世界でも手動なら共有ルートを見に行く。
        let world = await makeWorld("nosets-manual", withSet: false, network: true)
        await world.engine.sync(.manual)
        #expect(await world.server.requestLog.isEmpty == false)
    }

    @Test("作成元への追従は夜間と手動だけ", arguments: ShareSyncTrigger.allCases)
    func followsSource(trigger: ShareSyncTrigger) async {
        let world = await makeWorld("follow-\(trigger.rawValue)", withSet: true, network: true)
        await world.engine.sync(trigger)
        for _ in 0..<2_000 where world.engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
        if trigger.rule.followsSource {
            #expect(world.resolver.calls == 1, "作成元を 1 回引いていない")
        } else {
            #expect(world.resolver.calls == 0, "追従しない起こし方で作成元を引いた")
        }
    }
}
