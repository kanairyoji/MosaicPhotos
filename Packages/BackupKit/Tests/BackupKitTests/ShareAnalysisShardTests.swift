import DropboxCore
import Foundation
import Testing
@testable import BackupKit

// MARK: - シャード（ADR-183）

@Suite("解析データのシャード")
struct ShareAnalysisShardTests {

    private func hash(_ prefix: String) -> String {
        // 64 桁 hex（Dropbox の content_hash 形式）。
        String((prefix + String(repeating: "0", count: 64)).prefix(64))
    }

    @Test("content_hash の先頭 2 桁でシャードに分かれ、空のシャードは作らない")
    func groupsByHashPrefix() {
        let entries = [hash("ab12"): ShareAnalysisData.Entry(tags: ["a"]),
                       hash("ab34"): ShareAnalysisData.Entry(tags: ["b"]),
                       hash("ff00"): ShareAnalysisData.Entry(tags: ["c"])]
        let shards = ShareAnalysisData.shards(versions: ShareAnalysisData.Versions(tag: 1), entries: entries)
        #expect(Set(shards.keys) == ["ab", "ff"])
        #expect(shards["ab"]?.entries.count == 2)
        #expect(shards["ff"]?.entries.count == 1)
        #expect(ShareAnalysisData.shardFileName("ab") == "shard-ab.json")
        #expect(ShareAnalysisData.isAnalysisFileName("shard-ab.json"))
        #expect(ShareAnalysisData.isAnalysisFileName("analysis-v1.json"), "旧形式も読む")
        #expect(!ShareAnalysisData.isAnalysisFileName("IMG_1.jpg"))
    }

    @Test("差分計画: 無い/違うものだけ上げ、空になったシャードと旧形式は消す")
    func planUploadsOnlyChangedShards() {
        let local = ["ab": "H-ab", "cd": "H-cd", "ef": "H-ef"]
        let remote = [ShareAnalysisPlanning.RemoteFile(name: "shard-ab.json", contentHash: "H-ab"),   // 同じ → 触らない
                      ShareAnalysisPlanning.RemoteFile(name: "shard-cd.json", contentHash: "OLD"),    // 違う → 上げる
                      ShareAnalysisPlanning.RemoteFile(name: "shard-zz.json", contentHash: "H-zz"),   // 手元に無い → 消す
                      ShareAnalysisPlanning.RemoteFile(name: "analysis-v1.json", contentHash: "L")]   // 旧形式 → 消す
        let plan = ShareAnalysisPlanning.plan(local: local, remote: remote)
        #expect(plan.upload == ["cd", "ef"])
        #expect(plan.delete == ["analysis-v1.json", "shard-zz.json"])
    }

    @Test("シャードの JSON は決定的（同じ内容なら同じ content_hash）＝状態を持たずに比較できる")
    func encodingIsDeterministic() {
        let e = [hash("ab12"): ShareAnalysisData.Entry(tags: ["beach", "dog"], human: 2),
                 hash("ab34"): ShareAnalysisData.Entry(tags: ["sea"])]
        let a = ShareAnalysisData.shards(versions: ShareAnalysisData.Versions(tag: 1), entries: e)["ab"]!
        let b = ShareAnalysisData.shards(versions: ShareAnalysisData.Versions(tag: 1),
                                    entries: Dictionary(uniqueKeysWithValues: e.reversed()))["ab"]!
        #expect(ShareAnalysisData.encode(a) == ShareAnalysisData.encode(b))
        #expect(DropboxContentHash.hash(of: ShareAnalysisData.encode(a)!) == DropboxContentHash.hash(of: ShareAnalysisData.encode(b)!))
    }
}

// MARK: - 受信側（再帰一覧・シャードごとの rev）

@Suite("受信側の解析データ取得", .serialized)
struct ShareAnalysisFetchTests {

    private func hash(_ prefix: String) -> String {
        String((prefix + String(repeating: "0", count: 64)).prefix(64))
    }

    private func shardData(_ entries: [String: ShareAnalysisData.Entry]) -> Data {
        ShareAnalysisData.encode(ShareAnalysisData.File(versions: ShareAnalysisData.Versions(tag: 1), entries: entries))!
    }

    @Test("家族フォルダ 1 回の再帰一覧で、変わったシャードだけ取得する")
    func fetchesOnlyChangedShards() async {
        UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs)
        defer { UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs) }
        let server = FakeDropboxServer()
        let root = "/family/iphone-x/share"
        await server.seed(root, hash: "", isFolder: true)
        await server.seed("\(root)/people-a", hash: "", isFolder: true)
        await server.seed("\(root)/people-a/.mosaic-share", hash: "", isFolder: true)
        await server.seed("\(root)/people-a/img_1.jpg", hash: hash("ab12"))
        await server.upload(path: "\(root)/people-a/.mosaic-share/shard-ab.json",
                            data: shardData([hash("ab12"): ShareAnalysisData.Entry(tags: ["beach"])]))
        await server.upload(path: "\(root)/people-a/.mosaic-share/shard-cd.json",
                            data: shardData([hash("cd12"): ShareAnalysisData.Entry(tags: ["dog"])]))

        let fetch = ShareAnalysisFetch(httpClient: server)
        let first = await fetch.fetchUpdated(roots: [root], token: "t")
        #expect(first.count == 2)
        #expect(Set(first.map(\.setFolderPathLower)) == ["\(root)/people-a"])
        let listCalls = await server.requestLog.filter { $0.contains("list_folder") }.count
        #expect(listCalls == 1, "家族フォルダごとに 1 回の一覧で済むこと（以前はセットごと＝N+1 回）")

        for f in first { ShareAnalysisFetch.markImported(f) }
        // 1 シャードだけ変える → それだけ返る。
        await server.upload(path: "\(root)/people-a/.mosaic-share/shard-cd.json",
                            data: shardData([hash("cd12"): ShareAnalysisData.Entry(tags: ["dog", "park"])]))
        let second = await fetch.fetchUpdated(roots: [root], token: "t")
        #expect(second.map(\.analysisPathLower) == ["\(root)/people-a/.mosaic-share/shard-cd.json"])
    }

    @Test("旧形式 analysis-v1.json も読める")
    func readsLegacyFile() async {
        UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs)
        defer { UserDefaults.standard.removeObject(forKey: ShareSettingsKeys.importedAnalysisRevs) }
        let server = FakeDropboxServer()
        let root = "/family/iphone-y/share"
        await server.seed(root, hash: "", isFolder: true)
        await server.seed("\(root)/album-t", hash: "", isFolder: true)
        await server.seed("\(root)/album-t/.mosaic-share", hash: "", isFolder: true)
        await server.upload(path: "\(root)/album-t/.mosaic-share/analysis-v1.json",
                            data: shardData([hash("0a00"): ShareAnalysisData.Entry(tags: ["old"])]))
        let fetched = await ShareAnalysisFetch(httpClient: server).fetchUpdated(roots: [root], token: "t")
        #expect(fetched.count == 1)
        #expect(fetched.first?.file.entries[hash("0a00")]?.tags == ["old"])
    }
}

// MARK: - 作成元への自動追従（ADR-183 C）

@Suite("共有セットの作成元への追従", .serialized)
@MainActor
struct ShareRefreshFromSourceTests {

    private final class StubResolver: ShareSourceResolver {
        var members: [String: [String]] = [:]   // encoded key → メンバー
        func currentMembers(for key: ShareSourceKey) async -> [String]? { members[key.encoded] }
    }

    @Test("作成元が育ったら共有セットも増減し、作成元の無いセットは触らない")
    func refreshesAllSetsWithSource() async {
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set("/MosaicPhotos", forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for (id, hash) in [("a", "hA"), ("b", "hB"), ("c", "hC")] {
            await server.seed("/mosaicphotos/\(id).jpg", hash: hash)
            await store.upsertRecord(dropboxPath: "/mosaicphotos/\(id).jpg", localIdentifier: id,
                                     filename: "\(id).jpg", creationDate: nil, contentHash: hash,
                                     people: [], albums: [], isFavorite: false)
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        let resolver = StubResolver()
        engine.sourceResolver = resolver

        let person = ShareSourceKey.person(7)
        let setID = await engine.createSet(name: "太郎", refKeys: ["L-a", "L-b"], sourceKey: person.encoded)!
        let orphanID = await engine.createSet(name: "Trip", refKeys: ["L-a"])!   // 作成元なし
        // 作成元が育った: b が外れ c が入った。
        resolver.members[person.encoded] = ["L-a", "L-c"]

        let result = await engine.refreshAllFromSource()
        #expect(result.sets == 1)
        #expect(result.added == 1)
        #expect(result.removed == 1)
        #expect(Set(await store.shareItems(setID: setID).map(\.refKey)) == ["L-a", "L-c"])
        #expect(await store.shareItems(setID: orphanID).map(\.refKey) == ["L-a"], "作成元の無いセットは触らない")
    }
}
