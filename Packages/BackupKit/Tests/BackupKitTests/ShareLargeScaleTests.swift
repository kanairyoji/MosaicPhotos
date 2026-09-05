import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// 本物の Dropbox に近い条件（ページング・中間フォルダ・content_hash）で ADR-183 を通す。
///
/// ⚠️ 偽サーバーが 1 ページで全部返す限り、`has_more` → `list_folder/continue` の追従は
/// 一度も踏まれない。共有ルートは写真込みで 1 万件を超えるので、ここで**ページを跨がせる**。
@Suite("共有の規模（ページング・複数セット）", .serialized)
@MainActor
struct ShareLargeScaleTests {

    private static let backupRoot = "/MosaicPhotos"

    private final class StubAnalysis: ShareAnalysisSource {
        func analysisEntries(forRefKeys refKeys: [String]) async
            -> (versions: ShareSidecar.Versions, entries: [String: ShareSidecar.Entry]) {
            var entries: [String: ShareSidecar.Entry] = [:]
            for key in refKeys { entries[key] = ShareSidecar.Entry(tags: ["t-" + key]) }
            return (ShareSidecar.Versions(tag: 1, perception: 1, face: 1), entries)
        }
    }

    /// 64 桁 hex の content_hash（先頭 2 桁を散らしてシャードを複数作る）。
    private func hash(_ i: Int) -> String {
        let head = String(format: "%02x", i % 256)
        return String((head + String(repeating: "0", count: 62)).prefix(64))
    }

    /// `analysisSource` は weak なので、テストが握っておく。
    private let analysis = StubAnalysis()

    private func makeStack(photos: Int, pageSize: Int)
        async -> (engine: ShareSyncEngine, store: BackupStore, server: FakeDropboxServer) {
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        await server.setPageSize(pageSize)
        for i in 0..<photos {
            let path = "/mosaicphotos/backup/p\(i).jpg"
            await server.seed(path, hash: hash(i))
            await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(i)", filename: "p\(i).jpg",
                                     creationDate: nil, contentHash: hash(i),
                                     people: [], albums: [], isFavorite: false)
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        engine.analysisSource = analysis
        return (engine, store, server)
    }

    /// 反映が落ち着くまで待ってから、もう 1 回きっちり反映する。
    /// `createSet` は裏で反映を起こすので、直後の `syncNow()` は「実行中」に畳まれて即 return し得る。
    private func settle(_ engine: ShareSyncEngine) async {
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(5)) }
        await engine.syncNow()
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func count(_ server: FakeDropboxServer, _ endpoint: String) async -> Int {
        await server.requestLog.filter { $0.contains(endpoint) }.count
    }

    private func copiedCount(_ store: BackupStore) async -> Int {
        var n = 0
        for set in await store.allShareSets() {
            n += await store.shareItems(setID: set.id).filter { $0.state == .copied }.count
        }
        return n
    }

    @Test("再帰一覧はページを跨いでも全件返す（has_more → continue）")
    func recursiveListingFollowsPages() async {
        let server = FakeDropboxServer()
        await server.setPageSize(4)
        await server.seed("/r", hash: "", isFolder: true)
        for i in 0..<11 { await server.seed("/r/s\(i % 3)/f\(i).jpg", hash: hash(i)) }
        let listing = await DropboxShareCopier(httpClient: server).listFolder(path: "/r", token: "t", recursive: true)
        let files = listing?.filter { !$0.isFolder } ?? []
        #expect(files.count == 11, "ページの続きを取りこぼした")
        #expect(listing?.filter(\.isFolder).map(\.pathLower).sorted() == ["/r/s0", "/r/s1", "/r/s2"],
                "中間フォルダのエントリが無い（本物は必ず含む）")
        #expect(await count(server, "list_folder/continue") == 3, "14 エントリ / 4 件 = 4 ページ")
    }

    @Test("3 セット × 60 枚: 2 回目の反映はコピーもアップロードも無く、一覧は共有ルート 1 回だけ")
    func multiSetSyncConvergesWithOneListing() async {
        let (engine, store, server) = await makeStack(photos: 180, pageSize: 50)
        for s in 0..<3 {
            let keys = (0..<60).map { "L-p\(s * 60 + $0)" }
            _ = await engine.createSet(name: "Set\(s)", refKeys: keys)
        }
        await settle(engine)
        #expect(await copiedCount(store) == 180, "fixture: 全部コピーされていない")
        let shardFiles = await server.filePaths().filter { $0.contains("/.mosaic-share/shard-") }
        #expect(shardFiles.count > 3, "fixture: シャードが複数できていない（hash を散らしたか）")
        let uploadsAfterFirst = await server.uploadCount()
        let copiesAfterFirst = await count(server, "copy_batch_v2")

        let listingsBefore = await count(server, "files/list_folder")
        let continuesBefore = await count(server, "list_folder/continue")
        await engine.syncNow()
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(5)) }
        // 2 回目: 一覧は共有ルートの再帰 1 回（＋ページの続き）。セットごとの list_folder は無い。
        let listings = await count(server, "files/list_folder") - listingsBefore
        let continues = await count(server, "list_folder/continue") - continuesBefore
        #expect(listings - continues == 1, "セットごとに一覧している（初回一覧は 1 回のはず）")
        #expect(continues >= 1, "fixture: ページを跨いでいない（pageSize を下げること）")
        #expect(await server.uploadCount() == uploadsAfterFirst, "変わっていないシャードを上げ直している")
        #expect(await count(server, "copy_batch_v2") == copiesAfterFirst, "コピー済みをまたコピーしている")
    }

    @Test("1 枚外すと、そのシャードだけ消え、他のシャードは触らない")
    func removingOnePhotoTouchesOneShard() async {
        let (engine, _, server) = await makeStack(photos: 40, pageSize: 2_000)
        let keys = (0..<40).map { "L-p\($0)" }
        let setID = await engine.createSet(name: "Big", refKeys: keys)!
        await settle(engine)
        let uploadsAfterFirst = await server.uploadCount()
        let shardsBefore = await server.filePaths().filter { $0.contains("/.mosaic-share/shard-") }.count

        _ = await engine.removeItems(setID: setID, refKeys: ["L-p7"])   // hash 先頭 "07" → shard-07 だけ
        await settle(engine)

        let shardsAfter = await server.filePaths().filter { $0.contains("/.mosaic-share/shard-") }.count
        #expect(shardsAfter == shardsBefore - 1, "空になったシャードが消えていない")
        #expect(await server.uploadCount() == uploadsAfterFirst, "無関係なシャードを上げ直している")
    }

    @Test("同じ反映の中で、サイドカーの更新はコピーより先に行う")
    func sidecarUpdatesBeforeCopies() async {
        let (engine, _, server) = await makeStack(photos: 30, pageSize: 2_000)
        let setID = await engine.createSet(name: "Big", refKeys: (0..<20).map { "L-p\($0)" })!
        await settle(engine)

        // 10 枚追加（コピーが要る）＋ 1 枚外す（shard-03 が空になる＝サイドカーの変更が要る）。
        _ = await engine.addItems(setID: setID, refKeys: (20..<30).map { "L-p\($0)" })
        _ = await engine.removeItems(setID: setID, refKeys: ["L-p3"])
        let mark = await server.requestLog.count
        await settle(engine)

        // ⚠️ コピーは 500 枚/回・100 枚ごとのジョブ待ちで数分かかる。サイドカーを後回しにすると
        // 「反映を押しても何分も更新されない」（実フィードバック）。順序を回数ではなく**並び**で固定する。
        let log = Array(await server.requestLog.dropFirst(mark))
        let firstSidecarWrite = log.firstIndex { $0.contains("delete_batch") || $0.contains("files/upload") }
        let firstCopy = log.firstIndex { $0.contains("copy_batch_v2") }
        #expect(firstSidecarWrite != nil && firstCopy != nil, "fixture: どちらも起きていない")
        if let a = firstSidecarWrite, let b = firstCopy {
            #expect(a < b, "サイドカーの更新がコピーの後回しになっている")
        }
    }

    @Test("受信側もページを跨いで全シャードを拾う")
    func receiverFollowsPages() async {
        UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedSidecarRevs)
        defer { UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedSidecarRevs) }
        let server = FakeDropboxServer()
        await server.setPageSize(5)
        let root = "/family/x/share"
        await server.seed(root, hash: "", isFolder: true)
        for i in 0..<12 {
            await server.seed("\(root)/set/img\(i).jpg", hash: hash(i))
            let file = ShareSidecar.File(versions: ShareSidecar.Versions(tag: 1),
                                         entries: [hash(i): ShareSidecar.Entry(tags: ["x"])])
            await server.upload(path: "\(root)/set/.mosaic-share/shard-\(String(format: "%02x", i)).json",
                                data: ShareSidecar.encode(file)!)
        }
        let fetched = await ShareSidecarFetch(httpClient: server).fetchUpdated(roots: [root], token: "t")
        #expect(fetched.count == 12, "ページの続きにあるシャードを取りこぼした")
    }
}
