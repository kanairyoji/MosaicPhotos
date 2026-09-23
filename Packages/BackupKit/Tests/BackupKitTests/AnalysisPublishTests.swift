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
        #expect(roots.roots == ["/mosaicphotos/iphone-b/analysis"])
        #expect(roots.listedAll, "全部一覧できたのに失敗扱いになっている")
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
        #expect(roots.roots.isEmpty)
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
                                           previous: owner("iPhone-A"), now: now, photoCount: 10,
                                           published: true)
        #expect(mine.claimedAt == owner("iPhone-A").claimedAt, "自分の名乗りは名乗った日を保つ")
        #expect(mine.lastPublishedAt == now)

        let takenOver = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceName: "iPhone",
                                                previous: owner("iPhone-B"), now: now, photoCount: 10,
                                                published: true)
        #expect(takenOver.deviceFolder == "iPhone-A")
        #expect(takenOver.claimedAt == now, "引き継ぎは今から名乗り直す")
    }

    /// ⚠️ **端末名を変えても自分は自分**（レビュー指摘）。フォルダ名は端末名の変更・機種変更の
    /// 復元で変わるので、名前で比べると自分の名乗りを他人と誤認して公開が止まり、
    /// 自分の解析を自分で取り込み始める。
    @Test("端末名を変えても、安定 ID が同じなら自分の名乗りと分かる")
    func identityFollowsStableID() {
        let remote = AnalysisOwnership.Owner(deviceFolder: "iPhone-ABC123", deviceID: "ABC123",
                                             deviceName: "iPhone",
                                             claimedAt: Date(timeIntervalSince1970: 1_700_000_000))
        // 表示名が変わってフォルダ名が "iPad-ABC123" になっても、ID が同じなら自分。
        #expect(AnalysisOwnership.decide(remote: remote, myDeviceFolder: "iPad-ABC123",
                                         myDeviceID: "ABC123", acknowledgedDeviceFolder: nil) == .ours)
        // 別 ID は別端末。
        #expect(AnalysisOwnership.decide(remote: remote, myDeviceFolder: "iPhone-ZZZ999",
                                         myDeviceID: "ZZZ999",
                                         acknowledgedDeviceFolder: nil) == .otherDevice(remote))
    }

    /// ⚠️ 公開の前に名乗る回で「最後に公開できた日」を今にすると、1 枚も上げられない端末まで
    /// 「生きている」ように見え、引き継ぎの判断材料が死ぬ（レビュー指摘）。
    @Test("公開できていない回は「最後に公開できた日」を更新しない")
    func claimDoesNotFakeLastPublished() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceID: "A",
                                            myDeviceName: "iPhone", previous: nil, now: now,
                                            photoCount: 100, published: false)
        #expect(fresh.lastPublishedAt == nil)
        #expect(fresh.photoCount == nil)

        let after = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceID: "A",
                                            myDeviceName: "iPhone", previous: fresh, now: now,
                                            photoCount: 100, published: true)
        #expect(after.lastPublishedAt == now)
        #expect(after.claimedAt == fresh.claimedAt, "自分の名乗りは名乗った日を保つ")
    }

    @Test("JSON を往復できる")
    func codableRoundTrip() {
        let original = AnalysisOwnership.claim(myDeviceFolder: "iPhone-A", myDeviceName: "iPhone",
                                               previous: nil,
                                               now: Date(timeIntervalSince1970: 1_700_000_000),
                                               photoCount: 68_000, published: true)
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
        // 409（＝まだ無い）→ **名乗りを先に書く** → シャード → 最後に名乗りを更新。
        // ⚠️ 名乗りが先なのは、窓が切れる間際でも「この端末が公開者」を残すため
        // （実機ログ diagnostics-91: 最後に書いていたら名乗りごと落ちた）。
        let stub = SequencedClient([(409, #"{"error_summary":"path/not_found/.."}"#),
                                    (200, "{}"), (200, "{}"), (200, "{}")])
        let source = StubAnalysisSource()
        let publisher = publisher(stub, defaults: TestDefaults.scratch("publish-owner"),
                                  source: source)

        let outcome = await publisher.publish(photos: [photo])

        #expect(outcome.uploaded == 1)
        #expect(outcome.blockedBy == nil)
        // 1（名乗りの確認）＋ 1（先に名乗る）＋ 1（シャード）＋ 1（名乗りの更新）
        #expect(await stub.count() == 4, "名乗りを書いていない（次の端末が気づけない）")
        withExtendedLifetime(source) {}
    }
}

/// 上げ損ねたときの続き方（実機ログ diagnostics-86）。
@Suite("公開が途中で失敗したとき（ADR-222）")
@MainActor
struct AnalysisPublishFailureTests {

    /// ⚠️ 失敗した shard を飛ばして印を進めると、その shard は**一巡（半日）待たされる**。
    @Test("上げ損ねたら、次回はその shard から")
    func cursorStopsAtTheFailedShard() async {
        // 8 シャード × 1 枚。3 個目のアップロードで回線が切れる想定。
        let photos = (0..<8).map { i in
            AnalysisPublisher.CloudPhoto(
                refKey: "C-/p\(i).jpg",
                contentHash: String(format: "%02x", i) + String(repeating: "0", count: 62))
        }
        let source = StubAnalysisSource()
        let defaults = TestDefaults.scratch("publish-failure")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        let stub = SequencedClient([(409, "{}"),                     // 名乗りの確認（未設定）
                                    (200, "{}"),                     // 先に名乗る
                                    (200, "{}"), (200, "{}"),        // shard 00, 01 は成功
                                    (503, "{}"), (503, "{}"),        // shard 02 は 2 回とも失敗
                                    (200, "{}")])                    // 名乗りの更新
        let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                          httpClient: stub, defaults: defaults)

        let outcome = await publisher.publish(photos: photos, budget: 8)

        #expect(outcome.uploaded == 2)
        // 印は「済んだ最後」＝ shard 01 の次＝索引 2（= 失敗した shard 02）を指す。
        #expect(defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor) == 2, """
            印が窓の最後まで進んでいる。失敗した shard は一巡（32 窓＝半日）待たされる。
            """)
        withExtendedLifetime(source) {}
    }

    /// ⚠️ **429 は 1 回だけ待ち直す**（実機ログ diagnostics-89）。夜の窓では共有の反映と公開が
    /// 小さな JSON を続けざまに上げるので、バックアップの送信と重なると 429 が返る。
    /// 1 回で畳むと、そのシャードは次の窓（30 分後）まで来ない。
    @Test("429 は 1 回待ち直して、成功なら上げたことにする")
    func retriesOnceAfterRateLimit() async {
        let photos = [AnalysisPublisher.CloudPhoto(refKey: "C-/a.jpg",
                                                   contentHash: String(repeating: "a", count: 64))]
        let source = StubAnalysisSource()
        let defaults = TestDefaults.scratch("publish-429")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        // 名乗りの確認 → 先に名乗る → 429 → （待ち直して）成功 → 名乗りの更新。
        let stub = SequencedClient([(409, "{}"), (200, "{}"), (429, "{}"), (200, "{}"), (200, "{}")])
        let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                          httpClient: stub, defaults: defaults)

        let outcome = await publisher.publish(photos: photos, budget: 8)

        #expect(outcome.uploaded == 1, "429 で畳んでいる（次の窓まで来ない）")
        withExtendedLifetime(source) {}
    }

    /// 1 個も済まなければ印は据え置き（同じ窓をもう一度）。
    @Test("最初のシャードで失敗したら印は動かさない")
    func cursorStaysWhenNothingSucceeded() async {
        let photos = [AnalysisPublisher.CloudPhoto(refKey: "C-/a.jpg",
                                                   contentHash: String(repeating: "a", count: 64))]
        let source = StubAnalysisSource()
        let defaults = TestDefaults.scratch("publish-failure")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        defaults.set(0, forKey: ShareSettingsKeys.publishAnalysisCursor)
        // 名乗りの確認 → 先に名乗る → シャードは 2 回とも失敗 → 名乗りの更新。
        let stub = SequencedClient([(409, "{}"), (200, "{}"), (503, "{}"), (503, "{}"), (200, "{}")])
        let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                          httpClient: stub, defaults: defaults)

        let outcome = await publisher.publish(photos: photos, budget: 8)

        #expect(outcome.uploaded == 0)
        #expect(defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor) == 0)
        withExtendedLifetime(source) {}
    }

    /// ⚠️ **直らない失敗で止まらない**（レビュー指摘）。容量超過・権限エラーのように毎回落ちる
    /// シャードがあると、印が固まって 01〜ff が一度も公開されない。
    @Test("同じシャードで続けて失敗したら、飛ばして先へ進む")
    func skipsShardThatKeepsFailing() async {
        let photos = (0..<8).map { i in
            AnalysisPublisher.CloudPhoto(
                refKey: "C-/p\(i).jpg",
                contentHash: String(format: "%02x", i) + String(repeating: "0", count: 62))
        }
        let defaults = TestDefaults.scratch("publish-stuck")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        let source = StubAnalysisSource()

        // 先頭シャードが毎回落ちる回を繰り返す（名乗り確認 → 名乗り → 失敗 ×2 → 名乗り）。
        for _ in 0..<AnalysisPublisher.failureStreakLimit {
            let stub = SequencedClient([(409, "{}"), (200, "{}"), (507, "{}"), (507, "{}"), (200, "{}")])
            let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(),
                                              analysisSource: source, httpClient: stub,
                                              defaults: defaults)
            _ = await publisher.publish(photos: photos, budget: 1)
        }

        #expect(defaults.integer(forKey: ShareSettingsKeys.publishAnalysisCursor) == 1, """
            同じシャードで 3 回失敗しても印が動いていない（残りが永久に公開されない）。
            """)
        withExtendedLifetime(source) {}
    }

    /// ⚠️ **消せたときだけ記録を落とす**（レビュー指摘）。失敗しても落とすと、そのシャードは
    /// 二度と掃除の対象にならず、孤児が Dropbox に残り続ける。
    @Test("消えたシャードの削除に失敗したら、記録は残す")
    func keepsDigestWhenDeleteFails() async {
        let defaults = TestDefaults.scratch("publish-stale")
        defaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
        let digests = try! JSONEncoder().encode(["zz": "old"])
        defaults.set(digests, forKey: ShareSettingsKeys.publishedAnalysisDigests)
        let photos = [AnalysisPublisher.CloudPhoto(refKey: "C-/a.jpg",
                                                   contentHash: String(repeating: "a", count: 64))]
        let source = StubAnalysisSource()
        // 名乗り確認 → 名乗り → シャード → 削除（失敗）→ 名乗り。
        let stub = SequencedClient([(409, "{}"), (200, "{}"), (200, "{}"), (503, "{}"), (200, "{}")])
        let publisher = AnalysisPublisher(tokenProvider: StubPublishToken(), analysisSource: source,
                                          httpClient: stub, defaults: defaults)

        _ = await publisher.publish(photos: photos, budget: 8)

        let stored = (defaults.data(forKey: ShareSettingsKeys.publishedAnalysisDigests))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        #expect(stored["zz"] == "old", "消せていないのに記録を落とした（孤児が残り続ける）")
        withExtendedLifetime(source) {}
    }

    /// ⚠️ 既定は 1 か所にしか書かない（画面の `@AppStorage` も同じ値を使う）。
    /// 画面側だけ `= true` のままだったので、**トグルは ON に見えるのに公開は「設定がオフ」**
    /// という食い違いが実機で出た。
    @Test("公開の設定の既定は 1 か所（画面と読み出しで食い違わない）")
    func defaultIsSingleSourceOfTruth() {
        let defaults = TestDefaults.scratch("publish-default2")
        #expect(ShareSettingsKeys.isPublishAnalysisEnabled(defaults)
                == ShareSettingsKeys.publishAnalysisDefault)
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
        let stub = SequencedClient([(409, "{}")] + Array(repeating: (200, "{}"), count: 10))
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
