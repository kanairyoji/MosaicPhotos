import DropboxCore
import DropboxTestSupport
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// 期限切れの窓で、共有の反映を区切りで止める（diagnostics-109）。
///
/// 反映は構造化されていない Task で走るので、窓の `cancel()` が届かなかった。止めないと、
/// 投げた通信ごと 30 分止まり、次の窓の頭で失敗と飢餓を出す。
///
/// ⚠️ 区切りは 4 か所（セットの間・原本への問い合わせの間・解析データの前・コピーの塊の間）。
/// どこで頼むかで通る区切りが違うので、頼む瞬間を変えた 3 通りの fixture で当てる。
@Suite("共有の反映: 期限切れの窓で区切りで止める", .serialized)
@MainActor
struct ShareStopAtBreakTests {

    /// 指定した API を最初に投げる瞬間に一度だけ `hook` を呼ぶ口。
    actor HookClient: HTTPClient {
        let base: FakeDropboxServer
        private var hook: (suffix: String, run: @MainActor () -> Void)?
        init(base: FakeDropboxServer) { self.base = base }
        func setHook(on suffix: String, _ run: @escaping @MainActor () -> Void) { hook = (suffix, run) }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            if let hook, request.url?.absoluteString.hasSuffix(hook.suffix) == true {
                self.hook = nil
                await hook.run()
            }
            return try await base.data(for: request)
        }
    }

    private struct World {
        let engine: ShareSyncEngine
        let store: BackupStore
        let server: FakeDropboxServer
        let client: HookClient
        let shareRoot: String
        /// セット A（先に反映される）のフォルダ。消す候補の古いコピーを 1 つ置いてある。
        let folderA: String
    }

    /// セット A（端末写真 `photosInA` 枚）とセット B（端末写真 2 枚）。
    /// どれもバックアップ済みでまだ共有していない。反映はまだ走らせない。
    private func makeWorld(_ label: String, photosInA: Int = 2) async -> World {
        let defaults = TestDefaults.scratch("share-stop-\(label)")
        defaults.set("/MosaicPhotos", forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        let client = HookClient(base: server)
        let total = photosInA + 2
        for index in 0..<total {
            let path = "/mosaicphotos/backup/2020/p\(index).jpg"
            await server.seed(path, hash: "h\(index)")
            await store.upsertRecord(dropboxPath: path, localIdentifier: "p\(index)",
                                     filename: "p\(index).jpg", creationDate: nil, contentHash: "h\(index)",
                                     people: [], albums: [], isFavorite: false)
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: client, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        // ⚠️ セットは台帳へ直接作る。`engine.createSet` は反映を予約する（`Task { sync(.edited) }`）ので、
        // いつ走るか分からない回がテストの回と重なる（時間で待って避けるのはしない）。
        let membersA = (0..<photosInA).map { "L-p\($0)" }
        for (name, members) in [("A-\(label)", membersA),
                                ("B-\(label)", ["L-p\(total - 2)", "L-p\(total - 1)"])] {
            let set = await store.createShareSet(name: name, folderName: name)
            _ = await store.addShareItems(setID: set.id, refKeys: members)
        }

        let shareRoot = ShareSettingsKeys.currentShareRoot(defaults).lowercased()
        let folderA = await store.allShareSets().first { $0.name == "A-\(label)" }?.folderName.lowercased() ?? ""
        // 消す候補を 1 つ置く（メンバーでない古いコピー・中身はバックアップに在る）。
        // ⚠️ 無いと「止まったセットの掃除をしない」を外しても区別できない（fixture が結果を分けない）。
        await server.seed("\(shareRoot)/\(folderA)/stray.jpg", hash: "h\(total - 1)")
        return World(engine: engine, store: store, server: server, client: client,
                     shareRoot: shareRoot, folderA: folderA)
    }

    private func quiesce(_ engine: ShareSyncEngine) async {
        for _ in 0..<2_000 where engine.isSyncing { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// 共有フォルダに置かれた写真（解析データを除く）の数。
    private func sharedPhotoCount(_ world: World) async -> Int {
        await world.server.filePaths().filter {
            $0.hasPrefix(world.shareRoot + "/") && !$0.contains("/\(ShareAnalysisData.subfolderName)/")
        }.count
    }

    private func requests(_ world: World, _ endpoint: String) async -> Int {
        await world.server.requestLog.filter { $0.contains(endpoint) }.count
    }

    /// 消す・退避する往復の数。
    private func removals(_ world: World) async -> Int {
        await world.server.requestLog.filter { $0.contains("delete") || $0.contains("move") }.count
    }

    /// 頼んだ回の後、次の回（頼まない）が最後まで進むこと（頼みが持ち越されない・fixture が掃除を区別できる）。
    private func expectNextRunFinishes(_ world: World, expectedPhotos: Int,
                                       _ tap: DiagnosticsLog.Tap) async {
        await world.engine.syncNow()
        await quiesce(world.engine)
        #expect(await sharedPhotoCount(world) == expectedPhotos, "止めた後の回が続きを拾わない")
        #expect(await removals(world) > 0, "前提: 止めない回なら古いコピーを片付ける")
        #expect(await tap.count("share sync: 区切りで止めた") == 1, "次の回まで止まった")
    }

    @Test("最初のコピーの塊で頼むと: 次のセットに進まず、消さず、再走しない")
    func stopsBetweenSets() async {
        let world = await makeWorld("sets")
        #expect(await sharedPhotoCount(world) == 1, "前提: 古いコピーだけがある")
        let engine = world.engine
        await world.client.setHook(on: "/files/copy_batch_v2") { engine.stopAtNextBreak() }
        let tap = DiagnosticsLog.shared.tap()

        await engine.syncNow()
        await quiesce(engine)

        // 投げていた 1 塊（セット A の 2 枚）だけが置かれ、セット B には進まない。
        #expect(await requests(world, "copy_batch_v2") == 1, "区切りで止まらずに次のセットへ進んだ")
        #expect(await sharedPhotoCount(world) == 3)
        #expect(await removals(world) == 0, "止まった回に消した")
        #expect(await tap.count("share sync: 区切りで止めるよう頼んだ") == 1)
        #expect(await tap.count("share sync: 区切りで止めた（1/2 セットの後") == 1)
        #expect(engine.isSyncing == false)

        await expectNextRunFinishes(world, expectedPhotos: 4, tap)
    }

    @Test("コピーの塊が 2 つあるセットで、1 つ目の最中に頼むと: 2 つ目の塊を投げない")
    func stopsBetweenCopyChunks() async {
        let photos = ShareSyncEngine.copyChunkSize + 1
        let world = await makeWorld("chunks", photosInA: photos)
        let engine = world.engine
        await world.client.setHook(on: "/files/copy_batch_v2") { engine.stopAtNextBreak() }
        let tap = DiagnosticsLog.shared.tap()

        await engine.syncNow()
        await quiesce(engine)

        #expect(await requests(world, "copy_batch_v2") == 1, "区切りで止まらずに 2 つ目の塊を投げた")
        #expect(await sharedPhotoCount(world) == ShareSyncEngine.copyChunkSize + 1)
        #expect(await removals(world) == 0, "止まった回に消した")
        #expect(await tap.count("share sync: 区切りで止めた（1/2 セットの後") == 1)

        await expectNextRunFinishes(world, expectedPhotos: photos + 2, tap)
    }

    /// 固定の解析結果を返すスタブ。`tags` を変えると「解析が進んだ」＝シャードを上げ直す状況を作れる。
    final class StubAnalysis: ShareAnalysisSource {
        var tags = ["a"]
        func analysisEntries(forRefKeys refKeys: [String]) async
            -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
            var entries: [String: ShareAnalysisData.Entry] = [:]
            for key in refKeys { entries[key] = ShareAnalysisData.Entry(tags: tags) }
            return (ShareAnalysisData.Versions(tag: 1, perception: 1, face: 1), entries)
        }
    }

    @Test("原本への問い合わせの最中に頼むと: 残りを訊かず、そのセットの解析データもコピーも始めない")
    func stopsBeforeCopying() async {
        let world = await makeWorld("lookup")
        let engine = world.engine
        let analysis = StubAnalysis()
        engine.analysisSource = analysis
        // 同期一覧に載っていない原本だけを訊く（一覧そのものが空なら訊かない）ので、別の 1 枚を載せる。
        engine.cloudSourceHashProvider = { ["/camera/other.jpg": "hx"] }
        await engine.syncNow()   // 1 回落ち着かせる（全部置き、解析データも上げる）
        await quiesce(engine)
        #expect(await sharedPhotoCount(world) == 4, "前提: 落ち着いていない")

        // クラウド写真 2 枚をセット A に足し、解析も進める（止めなければシャードを上げ直す回）。
        // ⚠️ 2 枚＝問い合わせの区切りを通る。1 枚だと「残りを訊かない」を外しても区別できない。
        let cloud = ["/camera/c0.jpg", "/camera/c1.jpg"]
        for (index, path) in cloud.enumerated() { await world.server.seed(path, hash: "hc\(index)") }
        let setA = await world.store.allShareSets().first { $0.name == "A-lookup" }
        _ = await world.store.addShareItems(setID: setA!.id, refKeys: cloud.map { "C-\($0)" })
        analysis.tags = ["b"]
        let lookups = await requests(world, "get_metadata")
        let copies = await requests(world, "copy_batch_v2")
        let uploads = await requests(world, "files/upload")
        await world.client.setHook(on: "/files/get_metadata") { engine.stopAtNextBreak() }
        let tap = DiagnosticsLog.shared.tap()

        await engine.syncNow()
        await quiesce(engine)

        #expect(await requests(world, "get_metadata") - lookups == 1, "区切りで止まらずに次の原本を訊いた")
        #expect(await requests(world, "copy_batch_v2") == copies, "止まった回にコピーを始めた")
        #expect(await requests(world, "files/upload") == uploads, "止まった回に解析データを上げた")
        #expect(await tap.count("share sync: 区切りで止めた（1/2 セットの後") == 1)

        // 次の回（頼まない）は続きを拾う＝ fixture が「上げる／コピーする」を区別できる。
        await engine.syncNow()
        await quiesce(engine)
        #expect(await requests(world, "files/upload") > uploads, "前提: 止めない回なら解析データを上げ直す")
        #expect(await sharedPhotoCount(world) == 6, "止めた後の回が続きを拾わない")
    }

    @Test("走っていないときに頼んでも何もしない（次の回を止めない）")
    func noOpWhenIdle() async {
        let world = await makeWorld("idle")
        let tap = DiagnosticsLog.shared.tap()
        world.engine.stopAtNextBreak()
        #expect(await tap.count("share sync: 区切りで止めるよう頼んだ") == 0)

        await world.engine.syncNow()
        await quiesce(world.engine)
        #expect(await sharedPhotoCount(world) == 4)
        #expect(await tap.count("share sync: 区切りで止めた") == 0)
    }
}
