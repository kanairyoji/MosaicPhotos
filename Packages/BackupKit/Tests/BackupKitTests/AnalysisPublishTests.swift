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

/// **公開する端末は 1 台にする**ための名乗り（ADR-222 追補）。
///
/// 端末フォルダは分かれるのでファイルは壊れないが、2 台で公開すると同じ解析が台数ぶん
/// Dropbox に積まれる。ここでは「知らせる／引き継げる」の線を固定する
/// ——**止めきらない**こと（端末を失くしたら公開が永久に止まる）。
@Suite("解析を公開する端末の名乗り（ADR-222）")
struct AnalysisOwnershipTests {

    private func owner(_ folder: String) -> AnalysisOwnership.Owner {
        AnalysisOwnership.Owner(deviceFolder: folder, deviceName: "iPhone",
                                claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("誰も名乗っていなければ公開してよい")
    func unclaimed() {
        let decision = AnalysisOwnership.decide(remote: nil, myDeviceFolder: "iPhone-A",
                                                acknowledgedDeviceFolder: nil)
        #expect(decision == .unclaimed)
        #expect(AnalysisOwnership.allowsPublishing(decision))
    }

    @Test("自分が名乗っていれば公開してよい（大小は無視）")
    func ours() {
        let decision = AnalysisOwnership.decide(remote: owner("iphone-a"), myDeviceFolder: "iPhone-A",
                                                acknowledgedDeviceFolder: nil)
        #expect(decision == .ours)
        #expect(AnalysisOwnership.allowsPublishing(decision))
    }

    @Test("別の端末が名乗っていたら公開しない（知らせるだけ）")
    func otherDeviceBlocks() {
        let decision = AnalysisOwnership.decide(remote: owner("iPhone-B"), myDeviceFolder: "iPhone-A",
                                                acknowledgedDeviceFolder: nil)
        #expect(decision == .otherDevice(owner("iPhone-B")))
        #expect(AnalysisOwnership.allowsPublishing(decision) == false)
    }

    /// ⚠️ 端末を失くしたら引き継げないと困る。利用者が選べば**いつでも**引き継げる。
    @Test("利用者が承諾した相手なら引き継いで公開する")
    func acknowledgedTakesOver() {
        let decision = AnalysisOwnership.decide(remote: owner("iPhone-B"), myDeviceFolder: "iPhone-A",
                                                acknowledgedDeviceFolder: "iPhone-B")
        #expect(decision == .takenOver(owner("iPhone-B")))
        #expect(AnalysisOwnership.allowsPublishing(decision))
    }

    /// ⚠️ 承諾は**その相手に対してだけ**。3 台目が名乗ったらもう一度尋ねる
    /// （「一度 OK したから以後ずっと黙る」だと、増えた端末に気づけない）。
    @Test("承諾したのと別の端末が名乗ったら、また知らせる")
    func acknowledgementIsPerDevice() {
        let decision = AnalysisOwnership.decide(remote: owner("iPhone-C"), myDeviceFolder: "iPhone-A",
                                                acknowledgedDeviceFolder: "iPhone-B")
        #expect(AnalysisOwnership.allowsPublishing(decision) == false)
    }

    @Test("名乗りを書くと自分になる。自分の名乗りは claimedAt を引き継ぐ")
    func claimKeepsOriginalDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mine = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceName: "iPhone",
                                           previous: owner("iPhone-A"), now: now, photoCount: 10)
        #expect(mine.claimedAt == owner("iPhone-A").claimedAt, "自分の名乗りは名乗った日を保つ")
        #expect(mine.lastPublishedAt == now)

        let takenOver = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceName: "iPhone",
                                                previous: owner("iPhone-B"), now: now, photoCount: 10)
        #expect(takenOver.deviceFolder == "iPhone-A")
        #expect(takenOver.claimedAt == now, "引き継ぎは今から名乗り直す")
    }

    @Test("JSON を往復できる")
    func codableRoundTrip() {
        let original = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceName: "iPhone",
                                               previous: nil,
                                               now: Date(timeIntervalSince1970: 1_700_000_000),
                                               photoCount: 68_000)
        let data = AnalysisOwnership.encode(original)
        #expect(data != nil)
        #expect(AnalysisOwnership.decode(data!) == original)
    }

    /// ⚠️ **既定は OFF**（ADR-222 追補）。「気づいたら容量を倍使っていた」を既定にしない。
    @Test("公開の設定は既定オフ")
    func publishingIsOffByDefault() {
        let defaults = TestDefaults.scratch("publish-default")
        #expect(ShareSettingsKeys.isPublishAnalysisEnabled(defaults) == false)
    }
}

/// 名乗りが**公開そのもの**に効いていること（配線のテスト）。
@Suite("名乗りと公開の配線（ADR-222）")
@MainActor
struct AnalysisPublisherOwnershipTests {

    private func ownerJSON(_ folder: String) -> String {
        let owner = AnalysisOwnership.Owner(deviceFolder: folder, deviceName: "iPhone",
                                            claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return String(decoding: AnalysisOwnership.encode(owner)!, as: UTF8.self)
    }

    private func publisher(_ stub: SequencedClient, defaults: UserDefaults,
                           source: StubAnalysisSource) -> AnalysisPublisher {
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        return AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                 httpClient: stub, defaults: defaults)
    }

    private var photo: AnalysisPublisher.CloudPhoto {
        AnalysisPublisher.CloudPhoto(refKey: "C-/a.jpg",
                                     contentHash: String(repeating: "a", count: 64))
    }

    @Test("別の端末が名乗っていたら 1 バイトも上げない")
    func blockedByOtherDevice() async {
        // 名乗りのダウンロードだけで終わる（以降のリクエストは無い）。
        let stub = SequencedClient([(200, ownerJSON("iPhone-OTHER"))])
        // ⚠️ 供給元は**弱参照**で持たれる（アプリでは Composition Root が持つ）。
        // テストで手放すと publish は「解析の供給元が無い」で抜け、名乗りを見にすら行かない。
        let source = StubAnalysisSource()
        let publisher = publisher(stub, defaults: TestDefaults.scratch("publish-owner"),
                                  source: source)

        let outcome = await publisher.publish(photos: [photo])

        #expect(outcome.uploaded == 0)
        #expect(outcome.blockedBy?.deviceFolder == "iPhone-OTHER")
        #expect(await stub.count() == 1, "名乗りを見たあともリクエストを出している")
        withExtendedLifetime(source) {}
    }

    @Test("誰も名乗っていなければ公開し、名乗りを書く")
    func claimsAfterPublishing() async {
        // 409（＝まだ無い）→ シャードのアップロード → 名乗りのアップロード。
        let stub = SequencedClient([(409, #"{"error_summary":"path/not_found/.."}"#),
                                    (200, "{}"), (200, "{}")])
        let source = StubAnalysisSource()
        let publisher = publisher(stub, defaults: TestDefaults.scratch("publish-owner"),
                                  source: source)

        let outcome = await publisher.publish(photos: [photo])

        #expect(outcome.uploaded == 1)
        #expect(outcome.blockedBy == nil)
        // 1（名乗りの確認）＋ 1（シャード）＋ 1（名乗りの書き込み）
        #expect(await stub.count() == 3, "名乗りを書いていない（次の端末が気づけない）")
        withExtendedLifetime(source) {}
    }
}

/// 解析を 1 件だけ返すスタブ。
@MainActor
private final class StubAnalysisSource: ShareAnalysisSource {
    func analysisEntries(forRefKeys refKeys: [String]) async
        -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
        var entry = ShareAnalysisData.Entry()
        entry.tags = ["cat"]
        return (ShareAnalysisData.Versions(tag: 1, perception: 1, face: 1),
                Dictionary(uniqueKeysWithValues: refKeys.map { ($0, entry) }))
    }
}

private final class StubPublishToken: AccessTokenProvider {
    func freshAccessToken() async throws -> String { "tok" }
}
