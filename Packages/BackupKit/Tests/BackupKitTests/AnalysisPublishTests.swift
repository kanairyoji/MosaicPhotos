import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// **解析結果の公開**（ADR-222）: この回どのシャードを見るかと、他の端末の解析フォルダの見つけ方。
@Suite("解析の公開（ADR-222）")
struct AnalysisPublishTests {

    private func shards(_ count: Int) -> Set<String> {
        Set((0..<count).map { String(format: "%02x", $0) })
    }

    // MARK: - この回に見るシャード

    @Test("上限までのシャードを見て、残りは次回へ")
    func windowIsBounded() {
        let window = AnalysisPublishPlanning.window(presentShards: shards(60),
                                                    publishedDigests: [:], cursor: 0, budget: 8)
        #expect(window.shards.count == 8)
        #expect(window.remaining == 52)
        #expect(window.shards == (0..<8).map { String(format: "%02x", $0) }, "昇順で先頭から見る")
    }

    /// ⚠️ **先頭だけを見続けない**。続きから始めて一巡すること
    /// （最後に置いた公開に順番が回らなかったのと同じ飢餓を、シャードの中で作らない）。
    @Test("続きから一巡して、全シャードがいつか見られる")
    func windowRotatesThroughEveryShard() {
        let present = shards(60)
        var seen = Set<String>()
        var cursor = 0
        for _ in 0..<(60 / 8 + 2) {
            let window = AnalysisPublishPlanning.window(presentShards: present,
                                                        publishedDigests: [:], cursor: cursor, budget: 8)
            seen.formUnion(window.shards)
            cursor = window.nextCursor
        }
        #expect(seen == present)
    }

    @Test("写真が 1 枚も無ければ何も見ない")
    func emptyWindow() {
        let window = AnalysisPublishPlanning.window(presentShards: [], publishedDigests: [:],
                                                    cursor: 0, budget: 8)
        #expect(window.shards.isEmpty)
        #expect(window.remaining == 0)
    }

    // MARK: - 消えたシャード

    @Test("対象から消えたシャードは消す対象になる")
    func staleShards() {
        let window = AnalysisPublishPlanning.window(presentShards: shards(10),
                                                    publishedDigests: ["zz": "old"], cursor: 0)
        #expect(window.stale == ["shard-zz.json"])
    }

    @Test("解析が 1 件も無い回は、記録済みシャードを全部消す")
    func emptyRemovesAll() {
        let window = AnalysisPublishPlanning.window(presentShards: [],
                                                    publishedDigests: ["aa": "1", "bb": "2"], cursor: 0)
        #expect(window.shards.isEmpty)
        #expect(window.stale == ["shard-aa.json", "shard-bb.json"])
    }

    // MARK: - 指紋

    /// ⚠️ 同じ中身なら同じ指紋になること。`Entry` の辞書は順序を持たないので、既定のエンコーダだと
    /// バイト列が毎回変わり、**何も変わっていなくても全シャードを上げ直す**（テストで実際に踏んだ）。
    @Test("同じ中身のシャードは同じ指紋になる")
    func fingerprintIsStable() {
        var entries: [String: ShareAnalysisData.Entry] = [:]
        for i in 0..<50 {
            var entry = ShareAnalysisData.Entry()
            entry.tags = ["t\(i)"]
            entry.clip = String(repeating: "A", count: 64)
            entries[String(format: "%064x", i)] = entry
        }
        let versions = ShareAnalysisData.Versions(tag: 1, perception: 1, face: 1)
        let first = AnalysisPublishPlanning.encoded(
            ShareAnalysisData.File(versions: versions, entries: entries))!
        let second = AnalysisPublishPlanning.encoded(
            ShareAnalysisData.File(versions: versions, entries: entries))!
        #expect(AnalysisPublishPlanning.fingerprint(first)
                == AnalysisPublishPlanning.fingerprint(second))

        var changed = entries
        changed[String(format: "%064x", 999)] = ShareAnalysisData.Entry()
        let third = AnalysisPublishPlanning.encoded(
            ShareAnalysisData.File(versions: versions, entries: changed))!
        #expect(AnalysisPublishPlanning.fingerprint(first)
                != AnalysisPublishPlanning.fingerprint(third), "中身が変わったのに同じ指紋")
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

/// ADR-119 の規模テスト: **1 回の公開が、ライブラリ全体を実体化しない**こと。
///
/// ⚠️ 実機（diagnostics-85）で 637MB まで上がった形がこれ——「1 回ぶんに見える呼び出し」が
/// 9.7 万枚ぶんの解析取得（2,000 枚 × 49 回）と 256 シャードぶんの JSON になっていた。
/// **回数で見る**（時間は揺れるが回数は決定的）。
@Suite("公開 1 回の大きさ（ADR-119）")
@MainActor
struct AnalysisPublishScaleTests {

    @Test("1 回の公開で解析を訊くのは、この回に見るシャードのぶんだけ")
    func oneRunTouchesOnlyItsShards() async {
        // 2,560 枚を 256 シャードへ均す（1 シャード 10 枚）。
        let photos = (0..<2_560).map { i in
            AnalysisPublisher.CloudPhoto(
                refKey: "C-/p\(i).jpg",
                contentHash: String(format: "%02x", i % 256) + String(repeating: "0", count: 62)
                    + String(format: "%02x", i / 256))
        }
        let source = RecordingAnalysisSource()
        let defaults = TestDefaults.scratch("publish-scale")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        // 名乗りの確認（409＝未設定）→ シャード 8 個のアップロード → 名乗りの書き込み。
        let stub = SequencedClient([(409, "{}")] + Array(repeating: (200, "{}"), count: 9))
        let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                          httpClient: stub, defaults: defaults)

        let outcome = await publisher.publish(photos: photos, budget: 8)

        #expect(outcome.uploaded == 8, "この回のシャードを上げていない")
        // ⚠️ 件数ではなく**回数**。全件を 2,000 枚ずつ訊く実装に戻したら 2 回（2,560 枚）になる。
        #expect(await source.calls() == 8, "シャードごとに 1 回ではない")
        let asked = await source.askedRefKeys()
        #expect(asked == 80, "訊いた写真は 8 シャード × 10 枚のはず（\(asked) 枚を訊いている）")
        #expect(asked * 10 < photos.count, "1 回でライブラリの大半を実体化している")
        withExtendedLifetime(source) {}
    }
}

/// 何をどれだけ訊かれたか数えるスタブ。
@MainActor
private final class RecordingAnalysisSource: ShareAnalysisSource {
    private var callCount = 0
    private var refKeyCount = 0

    func analysisEntries(forRefKeys refKeys: [String]) async
        -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
        callCount += 1
        refKeyCount += refKeys.count
        var entry = ShareAnalysisData.Entry()
        entry.tags = ["cat"]
        return (ShareAnalysisData.Versions(tag: 1, perception: 1, face: 1),
                Dictionary(uniqueKeysWithValues: refKeys.map { ($0, entry) }))
    }

    func calls() -> Int { callCount }
    func askedRefKeys() -> Int { refKeyCount }
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
