import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

extension StandardSettingsSuite {
    /// **同じ Dropbox を 2 人が別々の端末で使い、別々の写真をお互いに共有する**（ADR-276 の確認）。
    ///
    /// 利用者がしたいこと: アカウントは 1 つ・端末は 2 台（Alice と Bob）。それぞれ自分の写真を
    /// 選んで相手に見せ、解析（タグ・顔・撮影日）も相手の端末に届けたい。
    ///
    /// ⚠️ ここは**いまの振る舞いを確かめる**テスト。望ましい振る舞いを `withKnownIssue` の中に書き、
    /// 「いまはそうなっていない」ことを記録する（直したら known issue が起きなくなって**落ちる**
    /// ＝書き換えを強制する）。前提が本当に成り立っているかは、`withKnownIssue` の外で確かめる
    /// （前提が崩れていて空振りしているだけ、を known issue で隠さないため）。
    ///
    /// 構成: Alice＝全部をバックアップ・セット「Album」（alice-0）／Bob＝共有する写真だけ・
    /// セット「Trip」（bob-1）。どちらも「写真の解析結果を共有」は ON（既定）。
    ///
    /// ⚠️ 限界: 表示（`MergedPhotoStore`）と解析候補（`AnalysisCandidates`）は iOS 専用のパッケージに
    /// あるので、ここでは**それらが読む材料**（どのパスが見え、どれが隠れるか）を本番と同じ規則で
    /// 組んで確かめる（規則そのものは `AnalysisCandidatesTests` が固定）。
    @Suite("同じ Dropbox・別々の端末（いまの振る舞いの確認）")
    @MainActor
    struct SameAccountDevicesScenarioTests {
        typealias Person = FamilySharingScenarioTests.Person

        static let aliceDevice = BackupDeviceIdentity.TestingIdentity(displayName: "iPhone", id: "AA11AA")
        static let bobDevice = BackupDeviceIdentity.TestingIdentity(displayName: "iPhone", id: "BB22BB")

        private func household() async -> (FakeDropboxCloud, Person, Person) {
            let cloud = FakeDropboxCloud()
            let alice = await Person("alice", cloud: cloud, photos: 3, destination: .dropbox,
                                     accountID: "family", identity: Self.aliceDevice)
            let bob = await Person("bob", cloud: cloud, photos: 3, destination: .disabled,
                                   accountID: "family", identity: Self.bobDevice)
            _ = await alice.asCurrentDevice { await alice.share.createSet(name: "Album", refKeys: ["L-alice-0"]) }
            _ = await bob.asCurrentDevice { await bob.share.createSet(name: "Trip", refKeys: ["L-bob-1"]) }
            for person in [alice, bob] {
                await person.backupPass()
                await person.syncShares()
            }
            return (cloud, alice, bob)
        }

        /// Dropbox 上のパス（このアカウント）のうち、この写真と同じ中身のもの。
        private func paths(of hash: String, on person: Person) async -> [String] {
            var out: [String] = []
            for path in await person.account.visibleFiles() where path.hasSuffix(".jpg") {
                if await person.account.contentHash(at: path) == hash { out.append(path) }
            }
            return out.sorted()
        }

        /// そのフォルダの解析データの中身（content_hash → タグ）。記録を持たない新しい取得で読む。
        private func analysis(under root: String, as person: Person) async -> [String: [String]] {
            let fetch = ShareAnalysisFetch(httpClient: person.account,
                                           defaults: TestDefaults.scratch("same-account-peek"))
            var out: [String: [String]] = [:]
            for fetched in await fetch.fetchUpdated(roots: [root], token: "t") {
                for (hash, entry) in fetched.file.entries { out[hash.lowercased()] = entry.tags ?? [] }
            }
            return out
        }

        // MARK: - 1. 見え方

        @Test("1. 上げた写真はすべて相手の端末にも見える（共有する写真だけなら、選んだ写真だけ）")
        func everythingUploadedIsVisibleToTheOtherDevice() async {
            let (_, alice, bob) = await household()
            #expect(alice.backupRoot != bob.backupRoot, "2 台の端末フォルダが分かれていない（前提が崩れている）")
            let files = await bob.account.visibleFiles()

            // Alice は全部をバックアップしている → Bob の端末から Alice のライブラリ全部が見える。
            for id in ["alice-0", "alice-1", "alice-2"] {
                #expect(await paths(of: alice.hash(id), on: bob).contains { $0.hasPrefix(alice.backupRoot.lowercased()) },
                        "全部をバックアップした Alice の \(id) が、同じ Dropbox の Bob から見えない")
            }
            // Bob は共有する写真だけ → Dropbox にあるのは選んだ bob-1 だけ。
            #expect(await paths(of: bob.hash("bob-1"), on: alice).count == 2, "bob-1 は Backup と Share の 2 か所にあるはず")
            for id in ["bob-0", "bob-2"] {
                #expect(await paths(of: bob.hash(id), on: alice).isEmpty, "選んでいない \(id) が Dropbox に出ている")
            }
            #expect(files == (await alice.account.visibleFiles()), "同じアカウントなのに 2 台で見えるものが違う")
        }

        // MARK: - 2. 解析

        @Test("2a. 自分の写真の解析は、端末で解析したものが「写真の解析結果を共有」で公開される")
        func ownPhotosAnalysisIsNotPublished() async {
            let (_, _, bob) = await household()
            let outcome = await bob.publishAnalysis()
            #expect(outcome.blockedBy == nil, "Bob が先に公開しているはず（前提）: \(outcome.message)")
            #expect(await bob.tags.hasAnalysis("L-bob-1"), "Bob の端末に bob-1 の解析が無い（前提が崩れている）")

            let published = await analysis(under: bob.backupRoot.replacingOccurrences(of: "/Backup", with: "/Analysis"),
                                           as: bob)
            #expect(!published.isEmpty, "Bob の公開が空（前提が崩れている）: \(outcome.message)")
            // Bob は Alice の写真を自分で解析して公開している（クラウド写真として見えるため）。
            #expect(published.values.contains { $0.first?.hasPrefix("bob:C-") == true })
            // ADR-276 で直した（以前は Backup のコピーの refKey で引いて空だった）。
            #expect(published[bob.hash("bob-1")] == ["bob:L-bob-1"],
                    "Bob の端末で解析した bob-1 が Bob の Analysis に無い")
        }

        @Test("2b. 別の端末が名乗っていても、自分の写真の解析だけは公開する（名乗りには触らない）")
        func onlyOneDeviceMayPublish() async {
            let (_, alice, bob) = await household()
            let first = await alice.publishAnalysis()
            #expect(first.blockedBy == nil && first.uploaded > 0, "Alice の公開が通らない（前提）: \(first.message)")
            let second = await bob.publishAnalysis()
            #expect(second.blockedBy?.deviceID == Self.aliceDevice.id,
                    "Bob を止めた相手が Alice でない: \(second.message)")
            // ADR-276 で直した（以前は Bob の公開が丸ごと止まっていた）。
            #expect(second.uploaded > 0, "Bob の公開が丸ごと止まった: \(second.message)")
            let bobPublished = await analysis(
                under: bob.backupRoot.replacingOccurrences(of: "/Backup", with: "/Analysis"), as: bob)
            #expect(bobPublished.keys.sorted() == [bob.hash("bob-1")],
                    "Bob が自分の写真以外も公開した（Dropbox にしか無い写真は名乗った 1 台に任せる）: \(bobPublished)")
            let owner = await alice.account.body(at: BackupLayout.analysisOwnerPath(root: Person.root))
                .flatMap(AnalysisOwnership.decode)
            #expect(owner?.deviceID == Self.aliceDevice.id, "Bob の公開で名乗りが書き換わった")
        }

        @Test("2c. Bob の端末で解析した bob-1 の解析が、Alice の端末に届く")
        func bobsAnalysisNeverReachesAlice() async {
            let (_, alice, bob) = await household()
            _ = await alice.publishAnalysis()
            _ = await bob.publishAnalysis()
            _ = await alice.receive()

            // 情報は Dropbox に在る: Bob の共有セットの解析データに、Bob の端末の解析が載っている。
            let inShare = await analysis(under: bob.shareRoot, as: alice)
            #expect(inShare[bob.hash("bob-1")] == ["bob:L-bob-1"], "Bob の共有セットに解析が無い（前提が崩れている）")
            // Alice は同じ Dropbox の他の端末の Analysis と Share の両方から取る（ADR-276）。
            #expect(alice.analysisRoots.contains(bob.shareRoot.lowercased()),
                    "Alice が Bob の Share を解析の取り込み先にしていない: \(alice.analysisRoots)")

            // ADR-276 で直した（Bob の Analysis に載るようになり、Alice はそこから取り込む）。
            #expect(alice.analysisRoots.contains { $0.hasPrefix(bob.backupRoot.lowercased()
                .replacingOccurrences(of: "/backup", with: "/analysis")) },
                    "Alice が Bob の Analysis を見つけていない: \(alice.analysisRoots)")
            #expect(alice.receivedTags[bob.hash("bob-1")] == ["bob:L-bob-1"],
                    "Alice に届いた bob-1 の解析: \(String(describing: alice.receivedTags[bob.hash("bob-1")]))")
        }

        @Test("2d. Bob が「写真の解析結果を共有」を使っていなくても、共有セットに入れた写真の解析は Alice に届く")
        func shareSetAnalysisReachesWithoutPublishing() async {
            let (_, alice, bob) = await household()
            // Bob は公開しない（publishAnalysis を呼ばない＝OFF と同じ）。
            _ = await alice.receive()
            #expect(!alice.analysisRoots.contains { $0.hasSuffix("/analysis") && $0.contains(Self.bobDevice.id.lowercased()) },
                    "Bob の Analysis があることになっている（前提が崩れている）: \(alice.analysisRoots)")
            #expect(alice.receivedTags[bob.hash("bob-1")] == ["bob:L-bob-1"],
                    "Bob の共有セットの解析が Alice に届かない")
        }

        // MARK: - 3. アルバム

        @Test("3. Bob の共有セットが、Alice の「受け取ったアルバム」に出る（提供者は Bob の端末）")
        func setsAreNotReceivedAlbums() async {
            let (_, alice, bob) = await household()
            #expect(bob.share.sets.contains { $0.name == "Trip" }, "Bob のセットが無い（前提）")
            #expect(await paths(of: bob.hash("bob-1"), on: alice).contains { $0.hasPrefix(bob.shareRoot.lowercased()) },
                    "Bob の共有コピーが Dropbox に無い（前提が崩れている）")
            let albums = await alice.receive()
            // ADR-276 で直した（以前は家族フォルダからしかアルバムを作らなかった）。
            let trip = albums.filter { $0.name.lowercased() == "trip" }
            #expect(trip.count == 1 && trip.first?.photoCount == 1, "Alice に見えるアルバム: \(albums.map(\.name))")
            // 同期一覧のパスの綴りをそのまま使う（テストは小文字のパスで回している）。
            #expect(trip.first?.providerName?.lowercased() == Self.bobDevice.folderName.lowercased())
            #expect(!albums.contains { $0.name.lowercased() == "album" }, "Alice 自身のセットを受け取ったアルバムにした")
            #expect(await bob.receive().map { $0.name.lowercased() } == ["album"], "Bob に Alice のセットが届かない")
        }

        // MARK: - 4. 二重

        /// 表示から外す規則（本番）: 自分の共有ルート（`ShareVisibility`）と、原本が端末にある
        /// 自分の Backup のコピー（`BackupCopyHiding`）。解析の候補から外す規則も同じ
        /// （`AnalysisCandidates.hiddenBackupCopyRefKeys`）。⚠️ どちらも**自分の**ものしか知らない。
        /// ADR-276 で 3 つ目の規則を足した: 他の端末の共有コピーのうち同じ中身が Share の外にもあるもの
        /// （`ShareCopyDuplicates` → `BackupCopyHiding.hiddenDuplicates`・残す方が出る画面だけ）。
        private func shown(_ paths: [String], on person: Person) async -> [String] {
            let own = Set(await person.store.allRecordsLite().map { $0.dropboxPath.lowercased() })
            let shareRoot = person.shareRoot.lowercased()
            var hashes: [String: String] = [:]
            for file in await person.account.visibleFiles() where file.hasSuffix(".jpg") {
                if let hash = await person.account.contentHash(at: file) { hashes[file] = hash }
            }
            let duplicates = await person.asCurrentDevice {
                ShareCopyDuplicates.otherDevicesShareCopies(
                    hashesByPath: hashes, backupRoot: Person.root,
                    ownDeviceFolder: BackupDeviceIdentity.currentFolderName(),
                    ownDeviceID: BackupDeviceIdentity.currentID())
            }
            return paths.filter { !own.contains($0) && !$0.hasPrefix(shareRoot + "/") && duplicates[$0] == nil }
        }

        @Test("4. Bob の写真は Alice の端末で 1 枚に見え、1 回だけ解析される（Backup と Share のコピーがあっても）")
        func otherDevicesPhotosAreDuplicated() async {
            let (_, alice, bob) = await household()
            let copies = await paths(of: bob.hash("bob-1"), on: alice)
            #expect(copies.count == 2, "前提: bob-1 は Backup と Share の 2 か所（\(copies)）")
            let shownOnAlice = await shown(copies, on: alice)
            var analyzedOnAlice = 0
            for path in copies where await alice.tags.hasAnalysis("C-\(path)") { analyzedOnAlice += 1 }

            // 比べる相手: 自分（Alice）の写真は 1 枚にしか見えない（規則が働いていることの確認）。
            let ownCopies = await paths(of: alice.hash("alice-0"), on: alice)
            #expect(ownCopies.count == 2, "前提: alice-0 も Backup と Share の 2 か所")
            #expect(await shown(ownCopies, on: alice).isEmpty, "自分の写真のコピーが見えている（規則の写しが本番と違う）")

            // ADR-276 で直した。残すのは Share の外（Bob の Backup）のコピー。
            #expect(shownOnAlice == copies.filter { $0.hasPrefix(bob.backupRoot.lowercased()) },
                    "Alice に見える bob-1: \(shownOnAlice)")
            #expect(analyzedOnAlice == 1, "Alice が bob-1 を \(analyzedOnAlice) 回解析する")
        }
    }
}
