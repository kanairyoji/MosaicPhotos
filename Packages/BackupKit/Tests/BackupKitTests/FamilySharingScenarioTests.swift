import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// 親の `StandardSettingsSuite` が直列にする（`.standard` の設定を書き換えるため）。
extension StandardSettingsSuite {
    /// **家族共有の通し**（ADR-275 追補）。別々の Dropbox アカウントの 2〜3 人が、
    /// それぞれの設定（全部をバックアップ／共有する写真だけ・提供する／しない）で
    /// 送り合い・受け合うのを、`FakeDropboxCloud`（共有フォルダは受ける人の Dropbox に現れる）の上で回す。
    ///
    /// どの組み合わせでも成り立つべき約束（`assertInvariants`）:
    ///   1. 自分の Backup には**自分の端末写真だけ**（受け取った写真は上げない）。
    ///      全部なら全部、共有する写真だけなら共有に入れた写真だけ
    ///   2. 相手が共有した写真が、受ける人のアルバムとして見え、解析も届く
    ///   3. 受ける人は**相手の共有フォルダへ一切書かない**（閲覧のみでも編集でも）
    ///   4. 相手の Backup の写真はアルバムに出さない（`/MosaicPhotos` ごと共有された場合）
    ///   5. もう 1 周回しても、何も書かない（冪等）
    ///
    /// ⚠️ **限界**: バックアップの 1 回は `BackupRunner.run` の写し（`SharedOnlyBackupScenarioTests` と
    /// 同じ。PhotoKit は macOS で使えない）。受ける側の「写真の一覧」はアプリの同期エンジン
    /// （`DropboxSyncEngine`・iOS 専用）ではなく、同じ API（`list_folder` 再帰）で読む。
    /// 解析の取り込み（タグ・顔をストアへ書く）はアプリ層なので、ここでは**届いたもの**まで。
    /// 同じ Dropbox の別端末どうし（ADR-222）は、端末フォルダ名がプロセスに 1 つなので作れない。
    ///
    /// ⚠️ `.serialized`: 本番の読み口が `UserDefaults.standard` の `backupDestination` /
    /// `shareProvideEnabled` を読むので、各人の回の間だけその人の設定に差し替える。
    @Suite("家族共有の通し（複数アカウント）")
    @MainActor
    struct FamilySharingScenarioTests {

        // MARK: - 人（アカウント＋端末＋記録＋共有エンジン）

        struct Photo { let id: String; let data: Data; let taken: Date }

        /// 解析の出どころ（refKey → タグ）。受ける側で「誰の何の写真の解析か」を読めるようにする。
        ///
        /// ⚠️ **「その端末に解析があるか」は本番の規則に合わせる**（`hasAnalysis`）。端末は
        /// 自分の端末写真（"L-"）を解析し、クラウド写真（"C-"）は**自分の Backup のコピーと
        /// 自分の Share の下を除いて**解析する——`AnalysisCandidates.hiddenBackupCopyRefKeys`
        /// （PhotosFeatureKit・`AnalysisCandidatesTests` が固定）と同じ規則。全部に解析があることに
        /// すると、「自分の写真の解析が公開されない」が偽物の上では見えなくなる。
        final class TagSource: ShareAnalysisSource {
            let owner: String
            var hasAnalysis: @MainActor (String) async -> Bool = { _ in true }
            init(owner: String) { self.owner = owner }
            func analysisEntries(forRefKeys refKeys: [String]) async
                -> (versions: ShareAnalysisData.Versions, entries: [String: ShareAnalysisData.Entry]) {
                var entries: [String: ShareAnalysisData.Entry] = [:]
                for key in refKeys where await hasAnalysis(key) {
                    // ⚠️ タグは短く（受信側の検証が長いタグを捨てる＝`maxTagLength`）。
                    // クラウド写真はパスが長いので、ファイル名だけを載せる。
                    let label = key.hasPrefix("C-") ? "C-" + (key as NSString).lastPathComponent : key
                    entries[key] = ShareAnalysisData.Entry(tags: ["\(owner):\(label)"])
                }
                return (ShareAnalysisData.Versions(tag: 1), entries)
            }
        }

        @MainActor
        final class Person {
            let name: String
            let account: FakeDropboxAccount
            let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
            let engine: BackupEngine
            let share: ShareSyncEngine
            let tags: TagSource
            let shareDefaults: UserDefaults
            let fetchDefaults: UserDefaults
            var destination: BackupDestination
            var provide: Bool { didSet { shareDefaults.set(provide, forKey: ShareSettingsKeys.provideEnabled) } }
            let library: [Photo]
            /// 受け取る家族フォルダ（自分の Dropbox で見えるパス）。
            var familyRoots: [String] = []
            /// 届いた解析（シャードのパス → その中身）。いま在るシャードだけを数える。
            private var shards: [String: [String: ShareAnalysisData.Entry]] = [:]

            static let root = "/MosaicPhotos"
            /// この人の端末（nil＝プロセスの端末）。同じ Dropbox に 2 台をつなぐときに分ける。
            let identity: BackupDeviceIdentity.TestingIdentity?
            let backupRoot: String
            let shareRoot: String
            let publishDefaults: UserDefaults

            /// - Parameters:
            ///   - accountID: 使う Dropbox アカウント（nil＝この人の名前のアカウント）。
            ///     同じ ID を 2 人に渡すと「同じ Dropbox を 2 台で使う」構成になる。
            ///   - identity: この人の端末（同じアカウントで 2 台にするときは別々に渡す）。
            init(_ name: String, cloud: FakeDropboxCloud, photos: Int,
                 destination: BackupDestination, provide: Bool = true,
                 accountID: String? = nil,
                 identity: BackupDeviceIdentity.TestingIdentity? = nil) async {
                self.name = name
                self.destination = destination
                self.provide = provide
                self.identity = identity
                (backupRoot, shareRoot) = BackupDeviceIdentity.$testingIdentity.withValue(identity) {
                    (BackupEngine.deviceBackupRoot(for: Person.root),
                     BackupLayout.shareRoot(root: Person.root,
                                            deviceFolder: BackupDeviceIdentity.currentFolderName()))
                }
                publishDefaults = TestDefaults.scratch("family-publish-\(name)")
                publishDefaults.set(true, forKey: ShareSettingsKeys.publishAnalysisEnabled)
                publishDefaults.set(Person.root, forKey: BackupSettingsKeys.dropboxFolder)
                account = await cloud.account(accountID ?? name)
                library = (0..<photos).map {
                    Photo(id: "\(name)-\($0)", data: Data("\(name)-photo-\($0)".utf8),
                          taken: Date(timeIntervalSince1970: 1_600_000_000 + Double($0) * 86_400))
                }
                engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"),
                                      httpClient: account, store: store, tokenProvider: FakeTokenProvider())
                shareDefaults = TestDefaults.scratch("family-share-\(name)")
                shareDefaults.set(provide, forKey: ShareSettingsKeys.provideEnabled)
                shareDefaults.set(Person.root, forKey: BackupSettingsKeys.dropboxFolder)
                fetchDefaults = TestDefaults.scratch("family-fetch-\(name)")
                let store = store
                share = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                        httpClient: account, defaults: shareDefaults)
                share.pollIntervalNs = 1_000_000
                share.maxPollAttempts = 3
                tags = TagSource(owner: name)
                share.analysisSource = tags
                let ownIDs = Set(library.map(\.id))
                let shareRootLower = shareRoot.lowercased()
                let identity = identity
                tags.hasAnalysis = { [store, account] key in
                    if key.hasPrefix("L-") { return ownIDs.contains(String(key.dropFirst(2))) }
                    guard key.hasPrefix("C-") else { return false }
                    let path = String(key.dropFirst(2)).lowercased()
                    if path == shareRootLower || path.hasPrefix(shareRootLower + "/") { return false }
                    // 自分の Backup のコピー（原本が端末にある）は解析しない。
                    let own = await store.allRecordsLite().map { $0.dropboxPath.lowercased() }
                    if own.contains(path) { return false }
                    // 同じ Dropbox の他の端末の共有コピー（同じ中身が Share の外にもある）も解析しない
                    // （ADR-276・`hiddenDuplicates` と同じ規則）。
                    var hashes: [String: String] = [:]
                    for file in await account.visibleFiles() where file.hasSuffix(".jpg") {
                        if let hash = await account.contentHash(at: file) { hashes[file] = hash }
                    }
                    let duplicates = BackupDeviceIdentity.$testingIdentity.withValue(identity) {
                        ShareCopyDuplicates.otherDevicesShareCopies(
                            hashesByPath: hashes, backupRoot: Person.root,
                            ownDeviceFolder: BackupDeviceIdentity.currentFolderName(),
                            ownDeviceID: BackupDeviceIdentity.currentID())
                    }
                    return duplicates[path] == nil
                }
                // 受け取った写真（"C-"）を共有し直すときの hash の表（アプリは同期キャッシュから引く）。
                let account = account
                share.cloudSourceHashProvider = {
                    var out: [String: String] = [:]
                    for path in await account.visibleFiles() {
                        if let hash = await account.contentHash(at: path) { out[path] = hash }
                    }
                    return out
                }
                await account.makeFolder(Person.root)
            }

            /// 本番の読み口（`.standard`）を、この人の設定にしている間だけ `body` を走らせる。
            func asCurrentDevice<T>(_ body: () async -> T) async -> T {
                let defaults = UserDefaults.standard
                let previous = (defaults.object(forKey: BackupSettingsKeys.destination),
                                defaults.object(forKey: ShareSettingsKeys.provideEnabled))
                defaults.set(destination.rawValue, forKey: BackupSettingsKeys.destination)
                defaults.set(provide, forKey: ShareSettingsKeys.provideEnabled)
                defer {
                    if let d = previous.0 { defaults.set(d, forKey: BackupSettingsKeys.destination) }
                    else { defaults.removeObject(forKey: BackupSettingsKeys.destination) }
                    if let p = previous.1 { defaults.set(p, forKey: ShareSettingsKeys.provideEnabled) }
                    else { defaults.removeObject(forKey: ShareSettingsKeys.provideEnabled) }
                }
                return await BackupDeviceIdentity.$testingIdentity.withValue(identity) { await body() }
            }

            /// 進捗台帳の写し（本番の `BackupProgressStore`）。
            var ledger: Set<String> = []

            /// バックアップの 1 回（写しは `BackupPassForTesting` の 1 つだけ・ADR-277）。
            @discardableResult
            func backupPass() async -> [String] {
                var ledger = ledger
                let uploaded = await asCurrentDevice {
                    await BackupPassForTesting.run(
                        library: library.map { .init(id: $0.id, data: $0.data, taken: $0.taken) },
                        ledger: &ledger, store: store, engine: engine, http: account,
                        path: { "\(backupRoot)/2020/2020-09/\($0.id).jpg" })
                }
                self.ledger = ledger
                return uploaded
            }

            func syncShares() async { await asCurrentDevice { await share.syncNow() } }

            /// 夜の 1 周ぶん（バックアップ → 反映 → 受け取り）。
            func fullRound() async -> [SharedAlbumDiscovery.Album] {
                await backupPass()
                await syncShares()
                return await receive()
            }

            /// 受け取り: 家族フォルダを一覧してアルバムを見つけ、解析を取りに行く。
            /// アプリの取り込み（`SharedAnalysisImporter`）と同じく、家族フォルダに加えて
            /// **同じ Dropbox の他の端末の `Analysis`**（ADR-222）からも解析を取る。
            func receive() async -> [SharedAlbumDiscovery.Album] {
                await asCurrentDevice {
                    var items: [String] = []
                    let copier = DropboxShareCopier(httpClient: account)
                    let fetch = ShareAnalysisFetch(httpClient: account, defaults: fetchDefaults)
                    let discovered = await fetch.accountAnalysisRoots(
                        backupRoot: Person.root, ownDeviceFolder: BackupDeviceIdentity.currentFolderName(),
                        token: "t")
                    analysisRoots = discovered.roots
                    var listedShards: Set<String> = []
                    for root in familyRoots + discovered.roots {
                        guard let listed = await copier.listFolder(path: root, token: "t", recursive: true)
                        else { continue }
                        if familyRoots.contains(root) {
                            items += listed.filter { !$0.isFolder && $0.pathLower.hasSuffix(".jpg") }.map(\.pathLower)
                        }
                        listedShards.formUnion(listed.filter { ShareAnalysisData.isAnalysisFileName($0.name) }
                            .map(\.pathLower))
                    }
                    for fetched in await fetch.fetchUpdated(roots: familyRoots + discovered.roots, token: "t",
                                                            discoveryComplete: discovered.listedAll) {
                        shards[fetched.analysisPathLower] = fetched.file.entries
                        fetch.markImported(fetched)
                    }
                    shards = shards.filter { listedShards.contains($0.key) }   // 消えたシャードは数えない
                    // アプリ（HomeView）と同じく、同期しているパス（自分の Dropbox の `/MosaicPhotos`
                    // ＋家族フォルダ）から、家族フォルダと同じ Dropbox の他の端末の共有セットを見つける。
                    let own = await copier.listFolder(path: Person.root, token: "t", recursive: true) ?? []
                    items += own.filter { !$0.isFolder && $0.pathLower.hasSuffix(".jpg") }.map(\.pathLower)
                    return SharedAlbumDiscovery.receivedAlbums(
                        itemPaths: items, familyRoots: familyRoots, backupRoot: Person.root,
                        ownDeviceFolder: BackupDeviceIdentity.currentFolderName(),
                        ownDeviceID: BackupDeviceIdentity.currentID())
                }
            }

            /// 直近の受け取りで見つけた、同じ Dropbox の他の端末の `Analysis`。
            private(set) var analysisRoots: [String] = []

            /// 「写真の解析結果を共有」（ADR-222）の 1 回。渡す写真はアプリ（`CloudAnalysisPublisher`）と
            /// 同じく**この端末が同期しているクラウド写真すべて**（`/MosaicPhotos` ＋家族フォルダ）。
            @discardableResult
            func publishAnalysis() async -> AnalysisPublisher.Outcome {
                await asCurrentDevice {
                    var cloud: [String: String] = [:]
                    let copier = DropboxShareCopier(httpClient: account)
                    for root in [Person.root] + familyRoots {
                        for file in await copier.listFolder(path: root, token: "t", recursive: true) ?? []
                        where !file.isFolder && file.pathLower.hasSuffix(".jpg") {
                            if let hash = file.contentHash { cloud[file.pathLower] = hash }
                        }
                    }
                    // 解析の候補から外した Backup のコピー＝自分の記録すべて（この世界では原本は
                    // 全部端末に残っている＝`hiddenBackupCopyRefKeys` が全部を外す）。
                    let hidden = await store.backupCopyIndex()
                    let photos = AnalysisPublishPlanning.publishablePhotos(cloud: cloud, hiddenBackupCopies: hidden)
                    let publisher = AnalysisPublisher(tokenProvider: FakeTokenProvider(), analysisSource: tags,
                                                      httpClient: account, defaults: publishDefaults)
                    return await publisher.publish(photos: photos)
                }
            }

            /// いま届いている解析（content_hash → タグ）。
            var receivedTags: [String: [String]] {
                shards.values.reduce(into: [:]) { out, entries in
                    for (hash, entry) in entries { out[hash.lowercased()] = entry.tags ?? [] }
                }
            }

            func hash(_ id: String) -> String {
                DropboxContentHash.hash(of: library.first { $0.id == id }!.data)
            }

            /// 自分の Backup にある写真の content_hash。
            func backedUpHashes() async -> Set<String> {
                var out: Set<String> = []
                for path in await account.visibleFiles()
                where path.hasPrefix(backupRoot.lowercased() + "/") && path.hasSuffix(".jpg") {
                    if let hash = await account.contentHash(at: path) { out.insert(hash) }
                }
                return out
            }

            /// 届いたアルバムのうち、この名前のもの（同名が複数あり得る）。
            func album(_ albums: [SharedAlbumDiscovery.Album], named name: String) -> [SharedAlbumDiscovery.Album] {
                albums.filter { $0.name.lowercased() == name.lowercased() }
            }
        }

        enum Layout: String, CaseIterable, Sendable, CustomTestStringConvertible {
            /// 共有フォルダ（`<root>/<端末>/Share`）だけを共有する。
            case shareFolder
            /// `/MosaicPhotos` ごと共有する（Backup も相手に見える。アルバムには出さない約束）。
            case wholeRoot
            var testDescription: String { rawValue }
        }

        /// `owner` の共有を `member` に見せる（Dropbox の共有）。受ける人の家族フォルダにも足す。
        private func connect(_ owner: Person, to member: Person, cloud: FakeDropboxCloud,
                             layout: Layout, access: FakeDropboxCloud.Access = .viewer) async {
            let folder = layout == .shareFolder ? owner.shareRoot : Person.root
            await owner.account.makeFolder(folder)   // まだ何も共有していなくても共有はできる
            let mount = await cloud.share(folder, of: owner.name, with: member.name, access: access)
            member.familyRoots.append(mount)
        }

        /// どの組み合わせでも成り立つべき約束。
        private func assertInvariants(_ people: [Person], shared: [String: [String]],
                                      sourceLocation: SourceLocation = #_sourceLocation) async {
            for person in people {
                let mine = Set(person.library.map { DropboxContentHash.hash(of: $0.data) })
                let backed = await person.backedUpHashes()
                #expect(backed.isSubset(of: mine),
                        "\(person.name) の Backup に自分の写真でないものがある（受け取った写真を上げた）",
                        sourceLocation: sourceLocation)
                let expected = person.destination == .dropbox
                    ? mine : Set((shared[person.name] ?? []).map(person.hash))
                #expect(backed == expected,
                        "\(person.name) の Backup が設定（\(person.destination)）と合わない: \(backed.count) 枚 / 期待 \(expected.count) 枚",
                        sourceLocation: sourceLocation)
                let intoShared = await person.account.writesIntoShared
                #expect(intoShared.isEmpty, "\(person.name) が他人の共有フォルダへ書いた: \(intoShared)",
                        sourceLocation: sourceLocation)
            }
        }

        // MARK: - 送り合い・受け合い（設定の全組み合わせ × 共有のしかた）

        nonisolated static let combinations: [(String, String, Layout)] = {
            var out: [(String, String, Layout)] = []
            for a in ["dropbox", "disabled"] { for b in ["dropbox", "disabled"] {
                for layout in Layout.allCases { out.append((a, b, layout)) }
            } }
            return out
        }()

        @Test("2 人が送り合い・受け合う（バックアップの設定 × 共有のしかた の全組み合わせ）",
              arguments: combinations)
        func mutualSharing(aliceSetting: String, bobSetting: String, layout: Layout) async {
            #expect(Self.combinations.count == 8, "組み合わせが作れていない（全部が空振りする）")
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 5,
                                     destination: BackupDestination(rawValue: aliceSetting)!)
            let bob = await Person("bob", cloud: cloud, photos: 4,
                                   destination: BackupDestination(rawValue: bobSetting)!)
            await connect(alice, to: bob, cloud: cloud, layout: layout)
            await connect(bob, to: alice, cloud: cloud, layout: layout)

            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-1", "L-alice-3"])
            _ = await bob.share.createSet(name: "Home", refKeys: ["L-bob-0"])

            // 1 周目: どちらが先に回っても、2 周すれば揃う（夜の順番は端末ごとに違う）。
            for _ in 0..<2 {
                _ = await alice.fullRound()
                _ = await bob.fullRound()
            }
            let bobSees = await bob.receive()
            let aliceSees = await alice.receive()

            let trip = bob.album(bobSees, named: "Trip")
            #expect(trip.count == 1 && trip.first?.photoCount == 2, "bob に alice のアルバムが届かない: \(bobSees)")
            #expect(bob.receivedTags[alice.hash("alice-1")] == ["alice:L-alice-1"], "alice の解析が bob に届かない")
            #expect(bob.receivedTags[alice.hash("alice-3")] == ["alice:L-alice-3"])
            let home = alice.album(aliceSees, named: "Home")
            #expect(home.count == 1 && home.first?.photoCount == 1, "alice に bob のアルバムが届かない: \(aliceSees)")
            #expect(alice.receivedTags[bob.hash("bob-0")] == ["bob:L-bob-0"])

            // 相手の Backup はアルバムに出ない（/MosaicPhotos ごと共有されていても）。
            #expect(bobSees.count == 1, "bob に alice の Backup がアルバムとして見えている: \(bobSees.map(\.folderPath))")
            #expect(aliceSees.count == 1, "alice に bob の Backup がアルバムとして見えている: \(aliceSees.map(\.folderPath))")

            await assertInvariants([alice, bob], shared: ["alice": ["alice-1", "alice-3"], "bob": ["bob-0"]])

            // 冪等: もう 1 周回しても誰も何も書かない。
            let writes = (await alice.account.writeCount(), await bob.account.writeCount())
            _ = await alice.fullRound()
            _ = await bob.fullRound()
            #expect(await alice.account.writeCount() == writes.0, "alice が変化の無い周に書いた")
            #expect(await bob.account.writeCount() == writes.1, "bob が変化の無い周に書いた")
        }

        // MARK: - 受けるだけ

        @Test("受けるだけの人（提供 OFF）: アルバムも解析も届き、共有する写真だけなら何も書かない",
              arguments: ["dropbox", "disabled"])
        func receiveOnly(bobSetting: String) async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 3, destination: .dropbox)
            let bob = await Person("bob", cloud: cloud, photos: 3,
                                   destination: BackupDestination(rawValue: bobSetting)!, provide: false)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-0", "L-alice-2"])
            // bob は共有セットを作るが「提供する」は OFF（＝作っても何も出さない）。
            _ = await bob.share.createSet(name: "Mine", refKeys: ["L-bob-1"])

            _ = await alice.fullRound()
            let bobSees = await bob.fullRound()

            #expect(bob.album(bobSees, named: "Trip").first?.photoCount == 2)
            #expect(bob.receivedTags.count == 2)
            await assertInvariants([alice, bob], shared: ["alice": ["alice-0", "alice-2"], "bob": []])
            if bob.destination == .disabled {
                let endpoints = await bob.account.requests.map(\.endpoint)
                #expect(await bob.account.writeCount() == 0,
                        "受けるだけ＋共有する写真だけの人が Dropbox に書いた: \(endpoints)")
            } else {
                #expect(await bob.account.uploadCount() == 3, "全部の人のバックアップが自分の 3 枚と違う")
            }
        }

        // MARK: - 送る人の変化が届く

        @Test("送る人が写真を外す → 受ける人のアルバムと解析から消える。セットを消すとアルバムごと消える",
              arguments: ["dropbox", "disabled"])
        func ownerChangesReachTheReceiver(aliceSetting: String) async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 4,
                                     destination: BackupDestination(rawValue: aliceSetting)!)
            let bob = await Person("bob", cloud: cloud, photos: 1, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            let setID = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-0", "L-alice-1", "L-alice-2"])!
            _ = await alice.fullRound()
            #expect(bob.album(await bob.receive(), named: "Trip").first?.photoCount == 3)

            // 受ける側の同期エンジンは差分で追う（家族フォルダに張ったカーソル）。
            let cursor = try? await latestCursor(bob, bob.familyRoots[0])

            _ = await alice.share.removeItems(setID: setID, refKeys: ["L-alice-1"])
            await alice.syncShares()
            let after = await bob.receive()
            #expect(bob.album(after, named: "Trip").first?.photoCount == 2, "外した写真が bob に残る")
            #expect(bob.receivedTags[alice.hash("alice-1")] == nil, "外した写真の解析が bob に残る")
            #expect(bob.receivedTags[alice.hash("alice-0")] != nil)
            if let cursor {
                let delta = try? await continueDelta(bob, cursor)
                #expect(delta?.contains("\"deleted\"") == true, "外した写真の削除が bob の差分に届かない: \(delta ?? "nil")")
            } else {
                Issue.record("差分カーソルが取れない")
            }
            // ADR-275: 外しても alice の Backup には残る。
            #expect(await alice.backedUpHashes().contains(alice.hash("alice-1")))

            _ = await alice.share.deleteSet(id: setID)
            await alice.syncShares()
            #expect(bob.album(await bob.receive(), named: "Trip").isEmpty, "消したセットが bob に残る")
            #expect(bob.receivedTags.isEmpty, "消したセットの解析が bob に残る")
        }

        /// diagnostics-82: 家族フォルダが消えても、受ける側は壊れず、自分の共有も止めない。
        @Test("送る人が共有を外す → 受ける人のアルバムが消え、受ける人自身の送信は続く")
        func unsharingDoesNotBreakTheReceiver() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 2, destination: .dropbox)
            let bob = await Person("bob", cloud: cloud, photos: 2, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            await connect(bob, to: alice, cloud: cloud, layout: .shareFolder)
            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-0"])
            _ = await bob.share.createSet(name: "Home", refKeys: ["L-bob-1"])
            _ = await alice.fullRound()
            _ = await bob.fullRound()
            #expect(bob.album(await bob.receive(), named: "Trip").count == 1)

            await cloud.unshare(bob.familyRoots[0], from: "bob")
            let bobSees = await bob.fullRound()
            #expect(bobSees.isEmpty, "外された共有のアルバムが残る: \(bobSees)")
            #expect(bob.receivedTags.isEmpty, "外された共有の解析が残る")

            _ = await bob.share.addItems(setID: bob.share.sets.first!.id, refKeys: ["L-bob-0"])
            _ = await bob.fullRound()
            #expect(alice.album(await alice.receive(), named: "Home").first?.photoCount == 2,
                    "bob の送信が、受けていた共有を外されたことで止まった")
            await assertInvariants([alice, bob], shared: ["alice": ["alice-0"], "bob": ["bob-0", "bob-1"]])
        }

        // MARK: - 受け取った写真を共有し直す

        @Test("受け取った写真（クラウド写真）を自分のセットで共有し直す: Backup には上げず、相手に届く")
        func resharingAReceivedPhoto() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 2, destination: .dropbox)
            let bob = await Person("bob", cloud: cloud, photos: 2, destination: .disabled)
            let carol = await Person("carol", cloud: cloud, photos: 1, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            await connect(bob, to: carol, cloud: cloud, layout: .shareFolder)
            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-1"])
            _ = await alice.fullRound()
            _ = await bob.receive()

            let received = await bob.account.visibleFiles()
                .first { $0.hasPrefix(bob.familyRoots[0].lowercased() + "/") && $0.hasSuffix(".jpg") }
            guard let received else {
                Issue.record("bob に写真が届いていない（前提が崩れている）")
                return
            }
            _ = await bob.share.createSet(name: "Forward", refKeys: ["C-\(received)"])
            let bobUploadsBefore = await bob.account.uploadCount()
            _ = await bob.fullRound()

            #expect(await bob.backedUpHashes().isEmpty, "受け取った写真を bob の Backup に上げた")
            let carolSees = await carol.receive()
            #expect(carol.album(carolSees, named: "Forward").first?.photoCount == 1,
                    "共有し直した写真が carol に届かない: \(carolSees)")
            let shareFiles = await bob.account.visibleFiles().filter { $0.hasPrefix(bob.shareRoot.lowercased()) }
            var hashes: Set<String> = []
            for path in shareFiles where path.hasSuffix(".jpg") {
                if let h = await bob.account.contentHash(at: path) { hashes.insert(h) }
            }
            #expect(hashes == [alice.hash("alice-1")], "共有し直した写真の中身が違う")
            // 写真の本体は上げない（コピーはサーバー内）。上がるのは解析データだけ。
            let photoUploads = await bob.account.requests
                .filter { $0.endpoint.contains("files/upload") && $0.paths.contains { $0.hasSuffix(".jpg") } }
            let uploadsDuring = await bob.account.uploadCount() - bobUploadsBefore
            #expect(photoUploads.isEmpty, "受け取った写真の本体を上げ直した（この周の upload \(uploadsDuring) 回）")
            await assertInvariants([alice, bob, carol], shared: ["alice": ["alice-1"], "bob": [], "carol": []])
        }

        // MARK: - 2 つの家族から同じ名前

        @Test("2 人が同じ名前のセットを送ってきても、別のアルバムとして両方届く")
        func twoSendersWithTheSameSetName() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 2, destination: .dropbox)
            let carol = await Person("carol", cloud: cloud, photos: 3, destination: .disabled)
            let bob = await Person("bob", cloud: cloud, photos: 1, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            await connect(carol, to: bob, cloud: cloud, layout: .shareFolder)
            #expect(bob.familyRoots.count == 2 && bob.familyRoots[0] != bob.familyRoots[1],
                    "2 つの共有フォルダが同じ名前で現れた: \(bob.familyRoots)")
            _ = await alice.share.createSet(name: "Family", refKeys: ["L-alice-0", "L-alice-1"])
            _ = await carol.share.createSet(name: "Family", refKeys: ["L-carol-2"])
            _ = await alice.fullRound()
            _ = await carol.fullRound()

            let family = bob.album(await bob.receive(), named: "Family")
            #expect(family.map(\.photoCount).sorted() == [1, 2], "同名のセットが混ざった／片方しか届かない: \(family)")
            #expect(Set(family.map(\.id)).count == 2)
            #expect(bob.receivedTags.count == 3)
            await assertInvariants([alice, carol, bob],
                                   shared: ["alice": ["alice-0", "alice-1"], "carol": ["carol-2"], "bob": []])
        }

        // MARK: - 編集の権限を渡されていても書かない

        @Test("編集の権限で共有されていても、受ける人は相手の共有フォルダを変えない")
        func editorAccessIsNotUsed() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 3, destination: .disabled)
            let bob = await Person("bob", cloud: cloud, photos: 3, destination: .dropbox)
            await connect(alice, to: bob, cloud: cloud, layout: .wholeRoot, access: .editor)
            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-0"])
            _ = await bob.share.createSet(name: "Home", refKeys: ["L-bob-2"])
            _ = await alice.fullRound()
            let aliceFiles = await alice.account.visibleFiles()
            for _ in 0..<2 { _ = await bob.fullRound() }
            #expect(await alice.account.visibleFiles() == aliceFiles, "bob の周で alice のファイルが変わった")
            await assertInvariants([alice, bob], shared: ["alice": ["alice-0"], "bob": ["bob-2"]])
        }

        // MARK: - 設定を途中で変える

        @Test("送る人が「共有する写真だけ」→「全部」に変えても、受ける人のアルバムは変わらない")
        func senderSwitchesToEverything() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 5, destination: .disabled)
            let bob = await Person("bob", cloud: cloud, photos: 1, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .wholeRoot)
            _ = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-4"])
            _ = await alice.fullRound()
            let before = await bob.receive()

            alice.destination = .dropbox
            _ = await alice.fullRound()
            let after = await bob.receive()
            #expect(after == before, "送る人のバックアップの設定で、受ける人のアルバムが変わった: \(after)")
            #expect(await alice.account.uploadCount() == 5 + (await shardUploads(alice)),
                    "共有のために上げた写真を上げ直した")
            await assertInvariants([alice, bob], shared: ["alice": ["alice-4"], "bob": []])
        }

        @Test("送る人が「提供する」を OFF にすると、それ以上は変わらない（置いたものは残る）")
        func senderTurnsProvideOff() async {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 3, destination: .disabled)
            let bob = await Person("bob", cloud: cloud, photos: 1, destination: .disabled)
            await connect(alice, to: bob, cloud: cloud, layout: .shareFolder)
            let setID = await alice.share.createSet(name: "Trip", refKeys: ["L-alice-0"])!
            _ = await alice.fullRound()
            #expect(bob.album(await bob.receive(), named: "Trip").first?.photoCount == 1)

            alice.provide = false
            _ = await alice.share.addItems(setID: setID, refKeys: ["L-alice-1"])
            let writes = await alice.account.writeCount()
            _ = await alice.fullRound()
            #expect(await alice.account.writeCount() == writes, "提供 OFF なのに書いた（写真の本体も含めて）")
            #expect(bob.album(await bob.receive(), named: "Trip").first?.photoCount == 1)
        }

        // MARK: - 部品

        private func latestCursor(_ person: Person, _ root: String) async throws -> String {
            var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/get_latest_cursor")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"path":"\#(root)","recursive":true}"#.utf8)
            let (data, _) = try await person.account.data(for: request)
            struct Cursor: Decodable { let cursor: String }
            return try JSONDecoder().decode(Cursor.self, from: data).cursor
        }

        private func continueDelta(_ person: Person, _ cursor: String) async throws -> String {
            var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"cursor":"\#(cursor)"}"#.utf8)
            let (data, _) = try await person.account.data(for: request)
            return String(decoding: data, as: UTF8.self)
        }

        /// 解析データ（シャード）の upload 回数。
        private func shardUploads(_ person: Person) async -> Int {
            await person.account.requests.filter {
                $0.endpoint.contains("files/upload") && $0.paths.contains { $0.contains(".mosaic-share") }
            }.count
        }
    }
}
