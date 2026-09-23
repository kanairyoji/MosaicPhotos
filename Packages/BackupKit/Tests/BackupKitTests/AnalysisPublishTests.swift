import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// **解析結果の公開**（ADR-222）: 上げ直す対象の選び方と、他の端末の解析フォルダの見つけ方。
@Suite("解析の公開（ADR-222）")
struct AnalysisPublishTests {

    private func entries(_ count: Int) -> [String: ShareAnalysisData.Entry] {
        var out: [String: ShareAnalysisData.Entry] = [:]
        for i in 0..<count {
            var entry = ShareAnalysisData.Entry()
            entry.tags = ["t\(i)"]
            // 鍵は content_hash（16 進 64 文字）。シャードは先頭 2 文字で分かれるので、
            // 先頭を振って 1 枚 1 シャードにする。
            out[String(format: "%02x", i) + String(repeating: "0", count: 62)] = entry
        }
        return out
    }

    private func files(_ count: Int) -> [String: ShareAnalysisData.File] {
        ShareAnalysisData.shards(versions: .init(tag: 1, perception: 1, face: 1),
                                 entries: entries(count))
    }

    // MARK: - 変わったシャードだけ

    @Test("初回は全部・2 回目は変わっていないので 0 件")
    func onlyChangedShards() {
        let files = files(40)
        let first = AnalysisPublishPlanning.plan(files: files, publishedDigests: [:], cursor: 0,
                                                 budget: 100)
        #expect(first.uploads.count == files.count)
        #expect(first.stale.isEmpty)

        var digests: [String: String] = [:]
        for upload in first.uploads { digests[upload.shard] = upload.digest }
        let second = AnalysisPublishPlanning.plan(files: files, publishedDigests: digests, cursor: 0,
                                                  budget: 100)
        #expect(second.uploads.isEmpty)
        #expect(second.remaining == 0)
    }

    @Test("中身が変わったシャードだけ上げ直す")
    func changedShardOnly() {
        let before = files(40)
        var digests: [String: String] = [:]
        for (shard, file) in before {
            digests[shard] = AnalysisPublishPlanning.fingerprint(AnalysisPublishPlanning.encoded(file)!)
        }
        // 1 枚足す（そのハッシュのシャードだけ変わる）。
        var grown = entries(40)
        var extra = ShareAnalysisData.Entry()
        extra.tags = ["new"]
        let newHash = "ff" + String(repeating: "0", count: 62)
        grown[newHash] = extra
        let after = ShareAnalysisData.shards(versions: .init(tag: 1, perception: 1, face: 1),
                                             entries: grown)
        let plan = AnalysisPublishPlanning.plan(files: after, publishedDigests: digests, cursor: 0,
                                                budget: 100)
        #expect(plan.uploads.count == 1)
        #expect(plan.uploads.first?.shard == "ff")
    }

    // MARK: - 上限と続き

    @Test("上限を超えるぶんは次回へ・続きから一巡する")
    func budgetRotates() {
        let files = files(60)
        var covered = Set<String>()
        var cursor = 0
        // 1 回 4 個ずつ。記録は付けない（全部が「変わっている」ままでも一巡すること）。
        for _ in 0..<(files.count / 4 + 2) {
            let plan = AnalysisPublishPlanning.plan(files: files, publishedDigests: [:],
                                                    cursor: cursor, budget: 4)
            #expect(plan.uploads.count <= 4)
            for upload in plan.uploads { covered.insert(upload.shard) }
            cursor = plan.nextCursor
        }
        #expect(covered.count == files.count)   // 先頭 4 個を取り直し続けない
    }

    @Test("対象から消えたシャードは消す対象になる")
    func staleShards() {
        let plan = AnalysisPublishPlanning.plan(files: files(10),
                                                publishedDigests: ["zz": "old"], cursor: 0)
        #expect(plan.stale == ["shard-zz.json"])
    }

    @Test("解析が 1 件も無い回は、記録済みシャードを全部消す")
    func emptyRemovesAll() {
        let plan = AnalysisPublishPlanning.plan(files: [:],
                                                publishedDigests: ["aa": "1", "bb": "2"], cursor: 0)
        #expect(plan.uploads.isEmpty)
        #expect(plan.stale == ["shard-aa.json", "shard-bb.json"])
    }

    // MARK: - 他の端末の解析フォルダを見つける

    @Test("ルート直下の端末フォルダから Analysis を見つける（自分の端末は除く）")
    func discoversOtherDevices() async {
        func folder(_ name: String, _ path: String) -> String {
            #"{".tag": "folder", "name": "\#(name)", "path_lower": "\#(path)"}"#
        }
        let root = #"{"entries": [\#(folder("iPhone-A", "/mosaicphotos/iphone-a")), \#(folder("iPhone-B", "/mosaicphotos/iphone-b"))], "cursor": "c", "has_more": false}"#
        let deviceB = #"{"entries": [\#(folder("Backup", "/mosaicphotos/iphone-b/backup")), \#(folder("Analysis", "/mosaicphotos/iphone-b/analysis"))], "cursor": "c", "has_more": false}"#
        let stub = SequencedClient([(200, root), (200, deviceB)])
        let roots = await ShareAnalysisFetch(httpClient: stub, defaults: TestDefaults.scratch("publish"))
            .accountAnalysisRoots(backupRoot: "/MosaicPhotos", ownDeviceFolder: "iPhone-A", token: "t")
        #expect(roots == ["/mosaicphotos/iphone-b/analysis"])
        // 自分の端末は一覧すらしない（ルート 1 回＋相手 1 回の 2 リクエスト）。
        #expect(await stub.count() == 2)
    }

    @Test("Analysis を持たない端末は候補にしない")
    func skipsDevicesWithoutAnalysis() async {
        let root = #"{"entries": [{".tag": "folder", "name": "iPhone-B", "path_lower": "/mosaicphotos/iphone-b"}], "cursor": "c", "has_more": false}"#
        let deviceB = #"{"entries": [{".tag": "folder", "name": "Backup", "path_lower": "/mosaicphotos/iphone-b/backup"}], "cursor": "c", "has_more": false}"#
        let stub = SequencedClient([(200, root), (200, deviceB)])
        let roots = await ShareAnalysisFetch(httpClient: stub, defaults: TestDefaults.scratch("publish"))
            .accountAnalysisRoots(backupRoot: "/MosaicPhotos", ownDeviceFolder: "iPhone-A", token: "t")
        #expect(roots.isEmpty)
    }
}

/// 応答を順番に返すスタブ。
private actor SequencedClient: HTTPClient {
    private var responses: [(status: Int, body: String)]
    private var requests = 0

    init(_ responses: [(status: Int, body: String)]) { self.responses = responses }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests += 1
        let next = responses.isEmpty ? (status: 500, body: "") : responses.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: next.status,
                                   httpVersion: nil, headerFields: nil)!
        return (Data(next.body.utf8), resp)
    }

    func count() -> Int { requests }
}
