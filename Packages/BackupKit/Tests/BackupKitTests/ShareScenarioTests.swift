import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// テストごとに独立した設定スイート（`.standard` を共有しない）。
/// クラウド共有の設定はプロセスに 1 つなので、並列に走る他テストが provide を OFF にすると
/// 反映が丸ごと空振りする（実際に踏んだ・原因が分かりにくい落ち方をする）。
func isolatedShareDefaults() -> UserDefaults {
    UserDefaults(suiteName: "share-tests-\(UUID().uuidString)") ?? .standard
}

/// クラウド共有の**シナリオテスト**（状態を持つ偽 Dropbox に対するエンドツーエンド検証）。
///
/// 純ロジックのテスト（`SharePureLogicTests`）が「1 回の計画が正しいか」を見るのに対し、
/// ここは **反映を複数回走らせて収束するか**を見る。実機で起きた障害はすべて
/// 「2 回目以降の反映で悪化する」形だったので、この層でしか捕まえられない。
@Suite("クラウド共有シナリオ（状態つき偽サーバー）")
@MainActor
struct ShareScenarioTests {

    private static let shareRoot = "/MosaicShare"


    /// 反映エンジン一式を組む。バックアップ済み写真を `backup` に与える。
    private func makeStack(backup: [(id: String, path: String, hash: String)])
        async -> (engine: ShareSyncEngine, store: BackupStore, server: FakeDropboxServer) {
        // ⚠️ `.standard` は使わない。共有の設定はプロセスに 1 つなので、並列に走る他テストが
        // provide を OFF にすると反映が丸ごと空振りする（実際に踏んだ・原因が分かりにくい）。
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.shareRoot, forKey: ShareSettingsKeys.shareRootFolder)

        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for item in backup {
            await server.seed(item.path, hash: item.hash)
            await store.upsertRecord(dropboxPath: item.path, localIdentifier: item.id,
                                     filename: (item.path as NSString).lastPathComponent,
                                     creationDate: nil, contentHash: item.hash,
                                     people: [], albums: [], isFavorite: false)
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store }, httpClient: server,
                                     defaults: defaults)
        // ジョブのポーリングはテストでは即座に打ち切る（本番は 0.5s × 480＝4 分）。
        engine.pollIntervalNs = 1_000_000     // 1ms
        engine.maxPollAttempts = 3
        return (engine, store, server)
    }

    /// 共有フォルダ内のファイル（フォルダを除く）。
    private func sharedFiles(_ server: FakeDropboxServer) async -> [String] {
        await server.filePaths().filter { $0.hasPrefix(Self.shareRoot.lowercased() + "/") }
    }

    /// セットフォルダの実パス（`<root>/<端末フォルダ>/<接頭辞-セット名>`・小文字）。
    /// 端末フォルダは Keychain 由来、接頭辞は種類由来なので、いずれも決め打ちせず組み立てる。
    private func setFolder(_ name: String, kind: ShareSourceKey.Kind? = nil) -> String {
        SharePlanning.setFolderPath(shareRoot: Self.shareRoot,
                                    folderName: ShareNaming.folderName(name, kind: kind),
                                    deviceFolder: BackupDeviceIdentity.currentFolderName())!
            .lowercased()
    }

    /// セットフォルダ配下に既存ファイルを置く（前提条件づくり）。
    private func seedInSet(_ server: FakeDropboxServer, set: String,
                           file: String, hash: String) async {
        await server.seed(setFolder(set), hash: "", isFolder: true)
        await server.seed("\(setFolder(set))/\(file)", hash: hash)
    }

    // MARK: - 基本

    @Test("作成 → 反映で全部コピーされ、2 回目以降は増えない（冪等）")
    func basicSyncIsIdempotent() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await engine.syncNow()
        let afterFirst = await sharedFiles(server)
        #expect(afterFirst.count == 2, "初回で 2 枚コピーされない: \(afterFirst)")

        // 何度走らせても増えない。
        await engine.syncNow()
        await engine.syncNow()
        let afterMore = await sharedFiles(server)
        #expect(afterMore == afterFirst, "反映のたびにファイルが増減する: \(afterMore)")
    }

    /// 接頭辞を入れる前に作った共有セットは、フォルダ名が `Trip` のまま残る。
    /// **作り直させずに**改名で追いつかせる（写真の再コピーは起きてはならない）。
    @Test("接頭辞なしの既存セットは反映時に改名される（写真は再コピーしない）")
    func legacySetIsRenamedInPlace() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        let sourceKey = ShareSourceKey.group(UUID()).encoded

        // 接頭辞が付く前の状態を再現（フォルダ名 = 素のセット名）。
        let set = await store.createLegacyShareSetForTesting(name: "Group", folderName: "Group",
                                                             sourceKey: sourceKey)
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-a", "L-b"])
        await engine.syncNow()

        let old = SharePlanning.setFolderPath(
            shareRoot: Self.shareRoot, folderName: "Group",
            deviceFolder: BackupDeviceIdentity.currentFolderName())!.lowercased()
        let new = setFolder("Group", kind: .group)
        let files = await sharedFiles(server)
        #expect(files.count == 2, "改名で写真が増減した: \(files)")
        #expect(files.allSatisfy { $0.hasPrefix(new + "/") },
                "新フォルダへ移動していない: \(files)")
        #expect(!files.contains { $0.hasPrefix(old + "/") }, "旧フォルダが残っている: \(files)")

        // ⚠️ 旧配置の探索は**一度きり**（規約: 無いものを繰り返し探さない）。
        let movesAfterFirst = await server.requestLog.filter { $0.contains("move_v2") }.count

        // 記録も張り替わっているので、次の反映で再コピーが起きない。
        await engine.syncNow()
        #expect(await sharedFiles(server) == files, "改名後の反映でファイルが変わった")
        #expect(await store.allShareSets().first?.folderName == "People-Group")
        let movesAfterSecond = await server.requestLog.filter { $0.contains("move_v2") }.count
        #expect(movesAfterSecond == movesAfterFirst,
                "反映のたびに旧配置を探している（往復の無駄）: \(movesAfterFirst) → \(movesAfterSecond)")
    }

    /// ⚠️ これが「Dropbox 上のパスが直らない」の正体（実フィードバック）。端末フォルダが
    /// 入る前のセットは共有ルート直下にあり、計画は `sharedPath` をそのまま再利用するので、
    /// **フォルダを作る先だけ新レイアウトになり写真は旧パスに書かれ続ける**。
    @Test("端末フォルダ以前の共有ルート直下セットも新レイアウトへ移動する")
    func legacyRootLevelSetIsMovedUnderDeviceFolder() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA")])
        let sourceKey = ShareSourceKey.group(UUID()).encoded

        // 旧レイアウト（`<root>/<セット名>`・端末フォルダ無し）を再現する。
        let legacy = SharePlanning.setFolderPath(shareRoot: Self.shareRoot,
                                                 folderName: "Group")!.lowercased()
        await server.seed(legacy, hash: "", isFolder: true)
        await server.seed("\(legacy)/a.jpg", hash: "hA")
        let set = await store.createLegacyShareSetForTesting(name: "Group", folderName: "Group",
                                                             sourceKey: sourceKey)
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-a"])
        await store.updateShareItems(setID: set.id, updates: [
            (refKey: "L-a", state: .copied, sourcePath: "/mosaicphotos/a.jpg",
             sharedPath: "\(legacy)/a.jpg", sharedContentHash: "hA")])

        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files == ["\(setFolder("Group", kind: .group))/a.jpg"],
                "新レイアウトへ移動していない: \(files)")
        #expect(await store.allShareSets().first?.folderName == "People-Group")

        // 記録も張り替わっているので、次の反映で再コピー（＝重複）が起きない。
        await engine.syncNow()
        #expect(await sharedFiles(server) == files, "移動後の反映でファイルが増減した")
    }

    /// 改名できない回（通信断・移動先が既にある）に記録だけ進めると、クラウド上の実体を
    /// 見失って全部コピーし直す。**失敗したら元のフォルダのまま使い続ける**こと。
    @Test("改名に失敗した回は元のフォルダ名のまま反映を続ける")
    func failedRenameKeepsOldFolder() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA")])
        let sourceKey = ShareSourceKey.group(UUID()).encoded
        let set = await store.createLegacyShareSetForTesting(name: "Group", folderName: "Group",
                                                             sourceKey: sourceKey)
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-a"])

        // 旧フォルダは反映済み、移動先も既にある状態（move は to/conflict で失敗する）。
        let oldFolder = SharePlanning.setFolderPath(
            shareRoot: Self.shareRoot, folderName: "Group",
            deviceFolder: BackupDeviceIdentity.currentFolderName())!.lowercased()
        await server.seed(oldFolder, hash: "", isFolder: true)
        await server.seed(setFolder("Group", kind: .group), hash: "", isFolder: true)
        await engine.syncNow()

        #expect(await store.allShareSets().first?.folderName == "Group",
                "改名に失敗したのに記録だけ進んだ")
        let files = await sharedFiles(server)
        #expect(!files.isEmpty && files.allSatisfy { $0.hasPrefix(oldFolder + "/") },
                "旧フォルダ配下に反映されていない: \(files)")
    }

    // MARK: - 共有の停止（共有元から）

    /// 共有元（人物/グループ/アルバム）のメニューから「クラウド共有を停止」できること。
    /// 停止＝共有フォルダごと削除。バックアップ（正本）には触れない。
    @Test("共有元から停止すると共有フォルダだけ消える（バックアップは残る）")
    func stopSharingRemovesOnlyTheSharedCopies() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        let groupID = UUID()
        let sourceKey = ShareSourceKey.group(groupID).encoded

        _ = await engine.createSet(name: "Family", refKeys: ["L-a", "L-b"], sourceKey: sourceKey)
        await engine.syncNow()
        #expect(await sharedFiles(server).count == 2)

        let setID = engine.sharedSetID(sourceKey: sourceKey, name: "Family")
        #expect(setID != nil, "共有中なのに停止対象が引けない（メニューが出ない）")
        #expect(await engine.stopSharing(setID: setID!))

        #expect(await sharedFiles(server).isEmpty, "共有フォルダのファイルが残っている")
        #expect(engine.sharedSetID(sourceKey: sourceKey, name: "Family") == nil,
                "停止後も共有中に見える")
        // 正本（バックアップ）は無傷。
        #expect(await server.filePaths().contains("/mosaicphotos/a.jpg"))
        #expect(await server.filePaths().contains("/mosaicphotos/b.jpg"))
    }

    /// AI アルバムとピープルグループに同じ名前が付いていても、停止対象を取り違えない。
    @Test("同名でも種類が違えば停止対象を取り違えない")
    func sharedSetLookupIsKindAware() async {
        let (engine, _, _) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        let groupKey = ShareSourceKey.group(UUID()).encoded
        let albumKey = ShareSourceKey.album("album-1").encoded

        _ = await engine.createSet(name: "Okinawa", refKeys: ["L-a"], sourceKey: groupKey)

        #expect(engine.sharedSetID(sourceKey: groupKey, name: "Okinawa") != nil)
        #expect(engine.sharedSetID(sourceKey: albumKey, name: "Okinawa") == nil,
                "共有していない AI アルバムに停止メニューが出る")
    }

    // MARK: - 実障害の再現

    /// diagnostics-52 の暴走そのもの: ジョブはサーバー側で完了するのにクライアントは
    /// タイムアウトする。旧実装は失敗扱いで autorename 再コピーし、重複を量産した。
    @Test("ジョブがタイムアウトしても（サーバーでは完了）重複を作らずに収束する")
    func timeoutButCompletedJobsConverge() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        await server.setJobsTimeOutButComplete(true)

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await engine.syncNow()   // クライアントは失敗と見なすが、サーバーにはファイルができている
        let afterTimeout = await sharedFiles(server)
        #expect(afterTimeout.count == 2, "サーバー側にコピーができていない前提が崩れた")

        // 以降は正常応答に戻し、再試行が**採用**で収束することを確認する。
        await server.setJobsTimeOutButComplete(false)
        await engine.syncNow()
        await engine.syncNow()
        let final = await sharedFiles(server)
        #expect(final.count == 2, "タイムアウト後の再試行で重複が生まれた: \(final)")
        #expect(!final.contains { $0.contains("(1)") || $0.contains(" 2.") },
                "autorename 形式または連番の重複ができた: \(final)")
    }

    /// diagnostics-55: コピーが失敗し続ける状況で掃除だけが走り、削除→再コピーの空回りに
    /// なった。コピー失敗時は掃除しない安全弁が効いているかを見る。
    @Test("コピーが失敗する回は掃除を行わない（空回りループの防止）")
    func skipsCleanupWhenCopyFails() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/img.jpg", "hSAME")])
        // 過去の暴走で生まれた重複を置いておく（元名と同じ内容＝掃除対象）。
        await seedInSet(server, set: "Trip", file: "img.jpg", hash: "hSAME")
        await seedInSet(server, set: "Trip", file: "img (1).jpg", hash: "hSAME")

        // 未コピーのアイテムを 1 つ作り、そのコピーを必ず失敗させる。
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "C-/other/x.jpg"])
        await server.setFailCopyPaths(["\(setFolder("Trip"))/x.jpg"])

        await engine.syncNow()
        let files = await sharedFiles(server)
        #expect(files.contains("\(setFolder("Trip"))/img (1).jpg"),
                "コピー失敗の回に掃除が走った（空回りループの入口）: \(files)")
    }

    @Test("コピーが完全に成功した回は重複を掃除する")
    func cleansDuplicatesOnSuccessfulRun() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/img.jpg", "hSAME")])
        await seedInSet(server, set: "Trip", file: "img.jpg", hash: "hSAME")
        await seedInSet(server, set: "Trip", file: "img (1).jpg", hash: "hSAME")

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(!files.contains("\(setFolder("Trip"))/img (1).jpg"), "重複が掃除されない: \(files)")
        #expect(files.contains("\(setFolder("Trip"))/img.jpg"), "正規ファイルまで消えた: \(files)")
    }

    /// 中身の違う「(1)」付きファイルは消してはいけない（ユーザーの写真）。
    @Test("中身の違う (N) 形式ファイルは掃除しない")
    func keepsDistinctFileNamedLikeDuplicate() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/img.jpg", "hA")])
        await seedInSet(server, set: "Trip", file: "img.jpg", hash: "hA")
        await seedInSet(server, set: "Trip", file: "img (1).jpg", hash: "hDIFFERENT")

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files.contains("\(setFolder("Trip"))/img (1).jpg"),
                "中身の違う写真を削除した: \(files)")
    }

    // MARK: - 自己修復

    @Test("共有側で消されたファイルは次の反映で復元される")
    func restoresExternallyDeletedFile() async {
        let (engine, _, server) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        #expect(await sharedFiles(server).count == 1)

        // 相手が共有フォルダから削除した状況。
        _ = try? await server.data(for: deleteRequest(path: "\(setFolder("Trip"))/a.jpg"))
        #expect(await sharedFiles(server).isEmpty)

        await engine.syncNow()
        #expect(await sharedFiles(server).count == 1, "外部削除から自己修復しない")
    }

    private func deleteRequest(path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/delete_batch")!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONEncoder().encode(["entries": [["path": path]]])
        return req
    }

    // MARK: - ライフサイクル（実フィードバック由来）

    @Test("セット削除で共有フォルダのファイルも消える")
    func deletingSetRemovesFiles() async {
        let (engine, store, server) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        #expect(await sharedFiles(server).count == 1)

        let setID = await store.allShareSets()[0].id
        _ = await engine.deleteSet(id: setID)
        #expect(await sharedFiles(server).isEmpty, "セット削除後も共有ファイルが残っている")
        #expect(await store.allShareSets().isEmpty)
    }

    @Test("単枚解除でそのファイルだけ消える")
    func removingOneItemDeletesOnlyThatFile() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await engine.syncNow()

        let setID = await store.allShareSets()[0].id
        await engine.removeItems(setID: setID, refKeys: ["L-a"])
        let files = await sharedFiles(server)
        #expect(files == ["\(setFolder("Trip"))/b.jpg"], "解除の結果が想定と違う: \(files)")
    }

    /// グループを作り直して再共有しても、Dropbox 上にフォルダが 2 つできない。
    @Test("同じ名前で再共有してもフォルダは 1 つのまま（写真が二重にならない）")
    func resharingDoesNotDuplicateFolders() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        let first = UUID(), second = UUID()

        _ = await engine.createSet(name: "Group", refKeys: ["L-a", "L-b"],
                                   sourceKey: ShareSourceKey.group(first).encoded)
        await engine.syncNow()
        // 解除 → 同名・同メンバーで作り直し。
        _ = await engine.createSet(name: "Group", refKeys: ["L-a", "L-b"],
                                   sourceKey: ShareSourceKey.group(second).encoded)
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files.count == 2, "写真が二重にコピーされた: \(files)")
        #expect(files.allSatisfy { $0.hasPrefix(setFolder("Group", kind: .group) + "/") },
                "期待するセットフォルダに入っていない: \(files)")
        #expect(Set(files.map { ($0 as NSString).deletingLastPathComponent }).count == 1,
                "フォルダが 2 つできた: \(files)")
    }

    @Test("メンバーが減ったセットを更新すると、外れた写真は共有からも消える")
    func updatingMembersRemovesDroppedPhotos() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await engine.syncNow()
        #expect(await sharedFiles(server).count == 2)

        let setID = await store.allShareSets()[0].id
        _ = await engine.updateSetMembers(setID: setID, refKeys: ["L-a"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files == ["\(setFolder("Trip"))/a.jpg"], "外れた写真が残っている: \(files)")
    }

    // MARK: - 障害耐性

    @Test("レート制限（429）が挟まっても最終的に収束する")
    func convergesDespiteRateLimiting() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB"),
            ("c", "/mosaicphotos/c.jpg", "hC")])
        await server.setRateLimit(everyNth: 3)   // 3 回に 1 回 429

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b", "L-c"])
        for _ in 0..<3 { await engine.syncNow() }

        await server.setRateLimit(everyNth: 0)
        await engine.syncNow()
        let files = await sharedFiles(server)
        #expect(files.count == 3, "レート制限後に収束しない: \(files)")
    }

    @Test("バックアップされていない端末写真はコピーされず、待ちとして残る")
    func unbackedPhotosWaitInsteadOfFailing() async {
        let (engine, store, server) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-missing"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files == ["\(setFolder("Trip"))/a.jpg"])
        let setID = await store.allShareSets()[0].id
        let items = await store.shareItems(setID: setID)
        #expect(items.first { $0.refKey == "L-missing" }?.state == .waitingBackup,
                "未バックアップが waitingBackup になっていない")
    }
}

@Suite("複数ユーザー共有と同名セット")
@MainActor
struct ShareMultiUserTests {

    /// 家族が同じ共有フォルダを使い、**同じセット名**を付けても互いを上書きしない。
    /// 提供側は `<root>/<端末フォルダ>/<セット名>/` に置く（ADR-41 と同じ分離）。
    @Test("同名セットでも端末フォルダで分離される")
    func setsAreIsolatedPerDevice() {
        let deviceA = SharePlanning.setFolderPath(shareRoot: "/MosaicShare",
                                                  folderName: "Family",
                                                  deviceFolder: "iPhone-AAAA")
        let deviceB = SharePlanning.setFolderPath(shareRoot: "/MosaicShare",
                                                  folderName: "Family",
                                                  deviceFolder: "iPad-BBBB")
        #expect(deviceA == "/MosaicShare/iPhone-AAAA/Family")
        #expect(deviceB == "/MosaicShare/iPad-BBBB/Family")
        #expect(deviceA != deviceB, "同名セットが同じパスになる（上書きが起きる）")
    }

    @Test("端末フォルダ名が不正なら nil（削除の暴発を防ぐ）")
    func rejectsUnsafeDeviceFolder() {
        for bad in ["", "  ", "..", "a/b"] {
            #expect(SharePlanning.setFolderPath(shareRoot: "/MosaicShare", folderName: "Set",
                                                deviceFolder: bad) == nil,
                    "危険な端末フォルダ名を通した: \(bad)")
        }
    }

    /// 受信側は階層の深さに依存せずセットを見つけ、提供者を区別できる。
    @Test("受信側は端末フォルダ配下のセットを提供者つきで発見する")
    func discoversNestedSetsWithProvider() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/MosaicShare/iPhone-AAAA/Family/a.jpg",
                        "/MosaicShare/iPhone-AAAA/Family/b.jpg",
                        "/MosaicShare/iPad-BBBB/Family/c.jpg"],
            familyRoots: ["/MosaicShare"])
        #expect(albums.count == 2, "同名セットが 1 つに潰れた: \(albums.map(\.folderPath))")
        #expect(albums.allSatisfy { $0.name == "Family" })
        #expect(Set(albums.compactMap(\.providerName)) == ["iPhone-AAAA", "iPad-BBBB"],
                "提供者を区別できない: \(albums.compactMap(\.providerName))")
    }

    @Test("従来の 1 階層構成（提供者なし）も引き続き発見できる")
    func stillDiscoversFlatLayout() {
        let albums = SharedAlbumDiscovery.albums(
            itemPaths: ["/MosaicShare/Trip/a.jpg", "/MosaicShare/Trip/b.jpg"],
            familyRoots: ["/MosaicShare"])
        #expect(albums.count == 1)
        #expect(albums.first?.name == "Trip")
        #expect(albums.first?.providerName == nil)
    }

    /// AI アルバムとピープルグループに同じ名前が付いていても、別セットとして扱う。
    @Test("同名でも種類が違えば別セットになる（AI アルバム vs ピープルグループ）")
    func sameNameDifferentKindsAreSeparateSets() async {
        let defaults = isolatedShareDefaults()
        defaults.set(false, forKey: ShareSettingsKeys.provideEnabled)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store },
                                     httpClient: FakeDropboxServer(), defaults: defaults)

        _ = await engine.createSet(name: "Okinawa", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.album("album-1").encoded)
        _ = await engine.createSet(name: "Okinawa", refKeys: ["L-b"],
                                   sourceKey: ShareSourceKey.group(UUID()).encoded)

        let sets = await store.allShareSets()
        #expect(sets.count == 2, "同名の別種が 1 セットに統合された（片方の共有を書き換える）")
        // フォルダ名は衝突回避で別になる。
        #expect(Set(sets.map(\.folderName)).count == 2, "フォルダ名が衝突している")
    }

    @Test("同じ種類・同じ名前なら再利用する（作り直しの継続）")
    func sameKindSameNameIsReused() async {
        let defaults = isolatedShareDefaults()
        defaults.set(false, forKey: ShareSettingsKeys.provideEnabled)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store },
                                     httpClient: FakeDropboxServer(), defaults: defaults)

        _ = await engine.createSet(name: "Family", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.group(UUID()).encoded)
        _ = await engine.createSet(name: "Family", refKeys: ["L-a", "L-b"],
                                   sourceKey: ShareSourceKey.group(UUID()).encoded)

        let sets = await store.allShareSets()
        #expect(sets.count == 1, "同種・同名なのにセットが増えた")
        #expect(await store.shareItems(setID: sets[0].id).count == 2, "内容が更新されていない")
    }
}
