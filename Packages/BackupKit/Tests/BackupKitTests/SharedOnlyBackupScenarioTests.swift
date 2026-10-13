import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// 親の `StandardSettingsSuite` が直列にする（`.standard` の設定を書き換えるため）。
extension StandardSettingsSuite {
    /// **「共有する写真だけ」を上げるバックアップ**の通し（ADR-275）。偽 Dropbox の上で
    /// 「バックアップの 1 回 → 共有の反映」を何度も回し、Dropbox に何が残るかを見る。
    ///
    /// 見ていること:
    ///   - 共有に入れた写真**だけ**が Backup に上がり、Share にコピーされる（他は 1 枚も上がらない）
    ///   - 2 回目以降は何も上げ直さない（`uploadCount` で数える＝ADR-119）
    ///   - 共有から外しても **Backup のファイルは残す**（Share のコピーだけ消える）
    ///   - 「提供する」が OFF なら共有メンバーでも上げない
    ///   - Dropbox 側で Backup のファイルが消されたら、照合 → 上げ直し → 反映で戻る
    ///   - 同時書き込みの 429 が来ても、次の回で収束する
    ///
    /// ⚠️ **限界**: バックアップの 1 回（`backupPass`）は `BackupRunner.run` の**写し**で、
    /// PHAsset の列挙・読み込みは模していない（PhotoKit は macOS のテストで使えない）。
    /// 写しているのは配管だけで、**判断はすべて本番の関数**（`BackupScope.current`・
    /// `BackupEngine.runnerShareMemberLocalIdentifiers`＝「提供する」の絞り込み・
    /// `BackupScopePolicy`）を呼ぶ。runner の配管（候補を共有メンバーに絞って引く・
    /// 上げるものが無ければ索引を作らない）は実機の確認に回す（device-verification 章 K）。
    ///
    /// ⚠️ `.serialized`: `UserDefaults.standard` の `backupDestination` / `shareProvideEnabled` を
    /// 書き換える（本番の読み口が `.standard` を読むため）。この 2 つを触るテストはここだけ。
    @Suite("共有する写真だけのバックアップ（偽 Dropbox の通し）")
    @MainActor
    struct SharedOnlyBackupScenarioTests {

        private static let root = "/MosaicPhotos"

        // MARK: - 世界（写真ライブラリ＋偽 Dropbox＋本物の記録・共有エンジン）

        @MainActor
        final class World {
            let server = FakeDropboxServer()
            let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
            let engine: BackupEngine
            let share: ShareSyncEngine
            /// 端末の写真（撮影日の昇順）。
            var library: [(id: String, data: Data, taken: Date)]
            let backupRoot = BackupEngine.deviceBackupRoot(for: SharedOnlyBackupScenarioTests.root)
            let shareRoot = BackupLayout.shareRoot(root: SharedOnlyBackupScenarioTests.root,
                                                   deviceFolder: BackupDeviceIdentity.currentFolderName())

            init(photos: Int) async {
                library = (0..<photos).map { index in
                    (id: "P\(index)", data: Data("photo-\(index)-bytes".utf8),
                     taken: Date(timeIntervalSince1970: 1_600_000_000 + Double(index) * 86_400))
                }
                engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"),
                                      httpClient: server, store: store, tokenProvider: FakeTokenProvider())
                let defaults = isolatedShareDefaults()
                defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
                defaults.set(SharedOnlyBackupScenarioTests.root, forKey: BackupSettingsKeys.dropboxFolder)
                let store = store
                share = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                        httpClient: server, defaults: defaults)
                share.pollIntervalNs = 1_000_000
                share.maxPollAttempts = 3
                await server.seed(SharedOnlyBackupScenarioTests.root, hash: "", isFolder: true)
            }

            /// 進捗台帳の写し（本番の `BackupProgressStore`）。記録と食い違う状態を作れるように持つ。
            var ledger: Set<String> = []
            /// 写真 ID → Backup でのファイル名（既定は ID）。中身も名前も同じ重複写真を作るのに使う。
            var fileStem: [String: String] = [:]

            /// バックアップの 1 回（写しは `BackupPassForTesting` の 1 つだけ・ADR-277）。上げた ID を返す。
            @discardableResult
            func backupPass(limit: Int = 0) async -> [String] {
                var ledger = ledger
                let uploaded = await BackupPassForTesting.run(
                    library: library.map { .init(id: $0.id, data: $0.data, taken: $0.taken) },
                    ledger: &ledger, store: store, engine: engine, http: server, limit: limit,
                    path: { [fileStem] in "\(backupRoot)/2020/2020-09/\(fileStem[$0.id] ?? $0.id).jpg" })
                self.ledger = ledger
                return uploaded
            }

            func backupPath(of photo: (id: String, data: Data, taken: Date)) -> String {
                "\(backupRoot)/2020/2020-09/\(photo.id).jpg"
            }

            /// Backup フォルダにある写真の ID（ファイル名から）。
            func backedUpIDs() async -> Set<String> {
                let prefix = backupRoot.lowercased() + "/"
                return Set(await server.filePaths().filter { $0.hasPrefix(prefix) && $0.hasSuffix(".jpg") }
                    .map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.uppercased() })
            }

            /// Share フォルダにある写真（中身で数える＝名前に印が付いていても同じ写真を同じと見る）。
            func sharedHashes() async -> Set<String> {
                let prefix = shareRoot.lowercased() + "/"
                var out: Set<String> = []
                for path in await server.filePaths() where path.hasPrefix(prefix) && path.hasSuffix(".jpg") {
                    if let hash = await server.contentHash(at: path) { out.insert(hash) }
                }
                return out
            }

            func hashes(_ ids: [String]) -> Set<String> {
                Set(library.filter { ids.contains($0.id) }.map { DropboxContentHash.hash(of: $0.data) })
            }
        }

        /// 設定（`.standard`）を決めて走らせ、終わったら戻す。
        private func with(scope destination: BackupDestination, provide: Bool = true,
                          _ body: () async throws -> Void) async rethrows {
            let defaults = UserDefaults.standard
            let previousDestination = defaults.object(forKey: BackupSettingsKeys.destination)
            let previousProvide = defaults.object(forKey: ShareSettingsKeys.provideEnabled)
            defaults.set(destination.rawValue, forKey: BackupSettingsKeys.destination)
            defaults.set(provide, forKey: ShareSettingsKeys.provideEnabled)
            defer {
                if let previousDestination { defaults.set(previousDestination, forKey: BackupSettingsKeys.destination) }
                else { defaults.removeObject(forKey: BackupSettingsKeys.destination) }
                if let previousProvide { defaults.set(previousProvide, forKey: ShareSettingsKeys.provideEnabled) }
                else { defaults.removeObject(forKey: ShareSettingsKeys.provideEnabled) }
            }
            try await body()
        }

        // MARK: - 基本

        @Test("共有に入れた写真だけが Backup に上がり、Share にコピーされる（他は 1 枚も上がらない）")
        func onlySharedPhotosReachDropbox() async {
            await with(scope: .disabled) {
                let world = await World(photos: 6)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P1", "L-P4"])

                // 反映を先に走らせても、上がっていない写真は「待ち」になるだけ（何も壊さない）。
                await world.share.syncNow()
                #expect(world.share.sets.first?.waitingBackup == 2)

                let uploaded = await world.backupPass()
                #expect(Set(uploaded) == ["P1", "P4"])
                #expect(await world.backedUpIDs() == ["P1", "P4"], "共有していない写真まで上がった")

                await world.share.syncNow()
                #expect(await world.sharedHashes() == world.hashes(["P1", "P4"]))
                #expect(world.share.sets.first?.waitingBackup == 0)
            }
        }

        @Test("2 回目以降は何も上げ直さず、何も増えない")
        func repeatedPassesAreQuiet() async {
            await with(scope: .disabled) {
                let world = await World(photos: 5)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P0", "L-P2"])
                await world.backupPass()
                await world.share.syncNow()
                let uploads = await world.server.uploadCount()
                let files = await world.server.filePaths()

                for _ in 0..<3 {
                    #expect(await world.backupPass().isEmpty)
                    await world.share.syncNow()
                }
                let after = await world.server.uploadCount()
                #expect(after == uploads, "上げ済みの写真を上げ直している（\(uploads) → \(after)）")
                #expect(await world.server.filePaths() == files, "何もしていないのにファイルが増減した")
            }
        }

        /// ⚠️ 記録は Dropbox のパスにつき 1 件で、同じパスを別の写真が 409 で「済み」と確かめると
        /// 持ち主が付け替わる（再取り込みで ID が変わった写真のため）。ADR-277 で「記録の無い共有メンバーは
        /// 上げ直す」にしたので、中身も名前も同じ重複写真を 2 枚とも共有すると、**毎回交互に上げ直していた**
        /// （独立レビューの指摘・ADR-278 追補 2）。
        @Test("中身も名前も同じ重複写真を 2 枚とも共有しても、毎回上げ直さない")
        func identicalDuplicatesDoNotPingPong() async {
            await with(scope: .disabled) {
                let world = await World(photos: 2)
                world.library[1] = (id: "P1", data: world.library[0].data, taken: world.library[0].taken)
                world.fileStem = ["P0": "IMG_0001", "P1": "IMG_0001"]
                _ = await world.share.createSet(name: "Dup", refKeys: ["L-P0", "L-P1"])
                await world.backupPass()
                await world.backupPass()
                let uploads = await world.server.uploadCount()
                for _ in 0..<3 {
                    #expect(await world.backupPass().isEmpty, "重複写真をまた上げ直した")
                }
                #expect(await world.server.uploadCount() == uploads, "重複写真を上げ直し続けている")
                await world.share.syncNow()
                let counts = await world.store.shareSyncedCounts().values.first
                #expect(counts?.waiting == 0, "片方がバックアップ待ちのまま: \(String(describing: counts))")
            }
        }

        /// 実機ログ diagnostics-108（ADR-277）: 共有の反映が何晩も `waitingBackup=1` を出し、
        /// バックアップは毎回「上げるもの無し」だった。台帳にだけ載って記録が無い写真は、
        /// バックアップから見ると「済み」、共有から見ると「待ち」で、どちらも動かない。
        /// ⚠️ 以前の写しは「済み」を記録だけで引いていたので、この状態を**作れなかった**。
        @Test("台帳にだけ載って記録の無い共有メンバーは、もう一度通して記録を作り、共有に届く",
              arguments: [BackupDestination.dropbox, .disabled])
        func ledgerOnlyShareMemberIsNotStuck(_ destination: BackupDestination) async {
            await with(scope: destination) {
                let world = await World(photos: 3)
                // 前提の状態: P0 は Dropbox に在り、台帳にも載っているが、記録が無い。
                let photo = world.library[0]
                await world.server.seed(world.backupPath(of: photo),
                                        hash: DropboxContentHash.hash(of: photo.data))
                world.ledger = ["P0"]
                #expect(await world.store.recordedLocalIdentifiers().isEmpty, "前提: 記録が無い")
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P0"])

                await world.backupPass()
                await world.share.syncNow()

                #expect(await world.store.recordedLocalIdentifiers().contains("P0"),
                        "記録が作られない（台帳を見て「済み」と判断している）")
                #expect(await world.sharedHashes() == world.hashes(["P0"]), "共有に届かない")
                let counts = await world.store.shareSyncedCounts().values.first
                #expect(counts?.waiting == 0, "まだバックアップ待ちになっている: \(String(describing: counts))")
            }
        }

        /// ⚠️ ADR-275 の決定: 共有から外しても Backup は**残す**（消すには「共有のためだけに上げた」
        /// 記録と削除の経路が要り、不可逆な操作が 1 つ増える）。
        @Test("共有から外すと Share のコピーは消え、Backup のファイルは残る（上げ直しもしない）")
        func stoppingSharingKeepsTheBackup() async {
            await with(scope: .disabled) {
                let world = await World(photos: 4)
                let setID = await world.share.createSet(name: "Trip", refKeys: ["L-P0", "L-P3"])
                await world.backupPass()
                await world.share.syncNow()
                let uploads = await world.server.uploadCount()

                _ = await world.share.removeItems(setID: setID!, refKeys: ["L-P3"])
                await world.share.syncNow()
                #expect(await world.sharedHashes() == world.hashes(["P0"]), "外した写真の共有コピーが残っている")
                #expect(await world.backedUpIDs() == ["P0", "P3"], "外した写真の Backup が消えた（残す決定）")

                #expect(await world.backupPass().isEmpty)
                #expect(await world.server.uploadCount() == uploads)

                // セットごと消しても同じ。
                _ = await world.share.deleteSet(id: setID!)
                await world.share.syncNow()
                #expect(await world.sharedHashes().isEmpty)
                #expect(await world.backedUpIDs() == ["P0", "P3"])
            }
        }

        @Test("あとから共有に足した写真だけが上がる")
        func addingLaterUploadsOnlyTheNewPhoto() async {
            await with(scope: .disabled) {
                let world = await World(photos: 5)
                let setID = await world.share.createSet(name: "Trip", refKeys: ["L-P0"])
                await world.backupPass()
                await world.share.syncNow()

                _ = await world.share.addItems(setID: setID!, refKeys: ["L-P2"])
                #expect(await world.backupPass() == ["P2"])
                await world.share.syncNow()
                #expect(await world.sharedHashes() == world.hashes(["P0", "P2"]))
                #expect(await world.backedUpIDs() == ["P0", "P2"])
            }
        }

        @Test("「提供する」が OFF なら、共有メンバーでも上げない")
        func provideOffUploadsNothing() async {
            await with(scope: .disabled, provide: false) {
                let world = await World(photos: 3)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P0", "L-P1"])
                #expect(await world.backupPass().isEmpty)
                #expect(await world.server.uploadCount() == 0, "共有しない設定なのに写真が Dropbox へ出た")
            }
        }

        @Test("共有セットが無ければ、写真ライブラリを見る前に終わる（何も上げない）")
        func nothingSharedMeansNothingUploaded() async {
            await with(scope: .disabled) {
                let world = await World(photos: 10)
                #expect(await world.backupPass().isEmpty)
                #expect(await world.server.uploadCount() == 0)
            }
        }

        // MARK: - 全部（自動バックアップ）との行き来

        @Test("全部: 共有で待たれている写真が最初に上がり、上限は共有の写真に効かない")
        func everythingUploadsSharedFirst() async {
            await with(scope: .dropbox) {
                let world = await World(photos: 6)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P5", "L-P3"])
                let first = await world.backupPass(limit: 1)
                #expect(first == ["P3", "P5", "P0"], "共有の写真が先頭に来ない／上限で切られた: \(first)")
                await world.backupPass()
                #expect(await world.backedUpIDs() == Set((0..<6).map { "P\($0)" }))
            }
        }

        @Test("共有する写真だけ → 全部に切り替えると、残りだけが上がる（共有済みは上げ直さない）")
        func switchingToEverythingUploadsTheRest() async {
            let world = await World(photos: 5)
            await with(scope: .disabled) {
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P1"])
                await world.backupPass()
            }
            await with(scope: .dropbox) {
                let rest = await world.backupPass()
                #expect(Set(rest) == ["P0", "P2", "P3", "P4"])
                #expect(await world.server.uploadCount() == 5, "共有のために上げた写真を上げ直した")
            }
        }

        // MARK: - Dropbox 側の変化

        /// Dropbox の Web で Backup の写真を消された。記録は「上げ済み」のままなので、
        /// 照合が記録を掃除しないと、共有はコピー元の無いまま失敗し続ける
        /// （ADR-275: 共有する写真だけの設定でも、上げたものがあれば照合を走らせる理由）。
        @Test("Backup の写真が Dropbox 側で消されたら、照合 → 上げ直し → 反映で戻る")
        func deletedBackupIsRecovered() async {
            await with(scope: .disabled) {
                let world = await World(photos: 3)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P0", "L-P1"])
                await world.backupPass()
                await world.share.syncNow()

                // 利用者が Dropbox で Backup も Share も片付けた。
                let p1 = world.library[1]
                await world.server.remove(world.backupPath(of: p1))
                for path in await world.server.filePaths() where path.hasPrefix(world.shareRoot.lowercased()) {
                    let hash = await world.server.contentHash(at: path)
                    if hash == DropboxContentHash.hash(of: p1.data) { await world.server.remove(path) }
                }
                await world.share.syncNow()
                #expect(await world.sharedHashes() == world.hashes(["P0"]), "コピー元が無いのに戻った（前提が崩れている）")
                #expect(await world.backupPass().isEmpty, "記録が残っているので、照合の前は上げ直さないはず")

                try? await Task.sleep(for: .milliseconds(20))   // 記録の時刻 < 一覧の時刻
                let reconciled = await world.engine.reconcileWithDropbox()
                #expect(reconciled?.removed == 1, "消えた写真の記録を掃除していない: \(String(describing: reconciled))")

                #expect(await world.backupPass() == ["P1"])
                await world.share.syncNow()
                #expect(await world.sharedHashes() == world.hashes(["P0", "P1"]))
            }
        }

        /// diagnostics-74 の形: 写真を上げている最中に共有の反映が書き込むと 429
        /// `too_many_write_operations`。落ちた分は「済み」にせず、次の回で収束すること。
        @Test("同時書き込みの 429 が来ても、次の回で収束する")
        func writeContentionConverges() async {
            await with(scope: .disabled) {
                let world = await World(photos: 8)
                _ = await world.share.createSet(name: "Trip", refKeys: (0..<8).map { "L-P\($0)" })
                await world.backupPass()
                await world.server.setResponseDelay(milliseconds: 20)
                await world.server.setMaxConcurrentWrites(1)

                // 上げ直しの対象を作る（Backup を何枚か消して照合で記録を落とす）。
                for photo in world.library.prefix(4) { await world.server.remove(world.backupPath(of: photo)) }
                try? await Task.sleep(for: .milliseconds(20))
                _ = await world.engine.reconcileWithDropbox()

                async let uploading = world.backupPass()
                async let syncing: Void = world.share.syncNow()
                _ = await (uploading, syncing)
                #expect(await world.server.transcript().contains("→ 429"),
                        "競合が一度も起きていない（このテストは何も確かめていない）")

                await world.server.setMaxConcurrentWrites(0)
                await world.server.setResponseDelay(milliseconds: 0)
                for _ in 0..<3 {
                    await world.backupPass()
                    await world.share.syncNow()
                }
                #expect(await world.backedUpIDs() == Set((0..<8).map { "P\($0)" }))
                #expect(await world.sharedHashes() == world.hashes((0..<8).map { "P\($0)" }),
                        "429 のあと収束していない")
            }
        }

        // MARK: - オフロード

        @Test("共有する写真だけの設定では、オフロードしない（共有しただけの写真を端末から消さない）")
        func offloadIsRefusedForSharedOnly() async {
            await with(scope: .disabled) {
                let world = await World(photos: 2)
                _ = await world.share.createSet(name: "Trip", refKeys: ["L-P0"])
                await world.backupPass()
                #expect(await world.engine.planOffload(limit: 10).items.isEmpty)
                let result = await world.engine.executeOffload(limit: 10)
                #expect(result.deleted.isEmpty && result.skipped.isEmpty)
                #expect(world.engine.log.contains { $0.message.contains("shared photos only") },
                        "見送った理由が記録に出ない")
            }
        }
    }
}
