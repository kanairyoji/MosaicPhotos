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

    /// ADR-175: 共有ルートはバックアップルート（`/MosaicPhotos`）の端末フォルダ配下 `Share/`。
    private static let backupRoot = "/MosaicPhotos"
    private static var shareRoot: String {
        BackupLayout.shareRoot(root: backupRoot, deviceFolder: BackupDeviceIdentity.currentFolderName())
    }


    /// 反映エンジン一式を組む。バックアップ済み写真を `backup` に与える。
    private func makeStack(backup: [(id: String, path: String, hash: String)])
        async -> (engine: ShareSyncEngine, store: BackupStore, server: FakeDropboxServer) {
        // ⚠️ `.standard` は使わない。共有の設定はプロセスに 1 つなので、並列に走る他テストが
        // provide を OFF にすると反映が丸ごと空振りする（実際に踏んだ・原因が分かりにくい）。
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)

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
                                    deviceFolder: nil)!   // shareRoot は端末フォルダ込み（ADR-175）
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

    /// ADR-175: 配置が変わったセットは**旧フォルダを動かさず**、新配置へコピーし直す。
    /// 既存データは移行しない（ユーザー判断）——旧フォルダは Dropbox に残り、人が片付ける。
    @Test("旧配置のセットは新配置へコピーし直され、旧フォルダは残る")
    func legacySetIsRecopiedUnderNewLayout() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        let sourceKey = ShareSourceKey.group(UUID()).encoded

        // 旧配置（`/MosaicShare/<端末>/Group`）にコピー済みだった状態を再現する。
        let legacyRoot = "/MosaicShare/\(BackupDeviceIdentity.currentFolderName())/Group".lowercased()
        await server.seed(legacyRoot, hash: "", isFolder: true)
        await server.seed("\(legacyRoot)/a.jpg", hash: "hA")
        await server.seed("\(legacyRoot)/b.jpg", hash: "hB")
        let set = await store.createLegacyShareSetForTesting(name: "Group", folderName: "Group",
                                                             sourceKey: sourceKey)
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-a", "L-b"])
        await store.updateShareItems(setID: set.id, updates: [
            (refKey: "L-a", state: .copied, sourcePath: "/mosaicphotos/a.jpg",
             sharedPath: "\(legacyRoot)/a.jpg", sharedContentHash: "hA"),
            (refKey: "L-b", state: .copied, sourcePath: "/mosaicphotos/b.jpg",
             sharedPath: "\(legacyRoot)/b.jpg", sharedContentHash: "hB")])

        await engine.syncNow()

        // 新配置へコピーされている（種類の接頭辞も付く）。
        let new = setFolder("Group", kind: .group)
        let files = await sharedFiles(server)
        #expect(files.sorted() == ["\(new)/a.jpg", "\(new)/b.jpg"], "新配置へコピーされていない: \(files)")
        #expect(await store.allShareSets().first?.folderName == "People-Group")
        // ⚠️ 旧フォルダは**動かさない**（移行しない方針）。
        #expect(await server.filePaths().contains("\(legacyRoot)/a.jpg"), "旧フォルダを動かしている")
        #expect(await server.requestLog.contains { $0.contains("move_v2") } == false,
                "旧配置を move しようとしている")

        // 記録は新配置を指しているので、次の反映で再コピー（＝重複）が起きない。
        await engine.syncNow()
        #expect(await sharedFiles(server) == files, "2 回目の反映でファイルが増減した")
    }

    /// 配置の検査は**一度きり**（規約: 無いものを繰り返し探さない）。
    @Test("配置の切り替えは 1 回だけで、以後の反映は通常どおり")
    func relayoutHappensOnce() async {
        let (engine, store, _) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        let set = await store.createLegacyShareSetForTesting(
            name: "Group", folderName: "Group", sourceKey: ShareSourceKey.group(UUID()).encoded)
        _ = await store.addShareItems(setID: set.id, refKeys: ["L-a"])

        await engine.syncNow()
        let after = await store.allShareSets().first
        #expect(after?.layoutVersion == ShareSet.currentLayoutVersion, "配置の版が更新されていない")
        #expect(after?.folderName == "People-Group")
    }

    // MARK: - 人物 ID の振り直し（レビュー指摘）

    /// ⚠️ `person-<clusterID>` の clusterID は**永続 ID ではない**。顔を全消去して再スキャンすると
    /// 0 から振り直されるため、別コンテナに残った共有セットの参照が**別人**を指し得る。
    /// そのまま反映すると、別人の写真を家族フォルダへ追加してしまう。
    @Test("顔の全消去後は人物由来の作成元キーを外す（別人の写真を共有しない）")
    func personSourcesAreDetachedWhenClusterIDsReset() async {
        let (engine, store, _) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "太郎", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.person(3).encoded)
        _ = await engine.createSet(name: "家族", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.group(UUID()).encoded)

        let detached = await engine.detachPersonSources()

        #expect(detached == 1, "人物セットの参照を外していない")
        let sets = await store.allShareSets()
        let person = sets.first { $0.name == "太郎" }
        let group = sets.first { $0.name == "家族" }
        #expect(person?.sourceKey == nil, "clusterID が再利用されると別人を指す")
        #expect(person != nil, "セット自体は残す（共有済みの写真はそのまま）")
        #expect(group?.sourceKey != nil, "グループ（UUID・永続）まで外している")
    }

    /// 外した後でも、同じ名前で共有し直せば同じセットに再び結び付く（写真は二重にならない）。
    @Test("参照を外した後、同じ名前の共有で再び結び付く")
    func detachedSetRelinksByName() async {
        let (engine, store, _) = await makeStack(backup: [("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "太郎", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.person(3).encoded)
        _ = await engine.detachPersonSources()

        // 再スキャン後、同じ人物（番号は違う）を共有し直す。
        _ = await engine.createSet(name: "太郎", refKeys: ["L-a"],
                                   sourceKey: ShareSourceKey.person(11).encoded)

        let sets = await store.allShareSets()
        #expect(sets.count == 1, "セットが二重にできた（同じ写真がもう一組コピーされる）")
        #expect(sets.first?.sourceKey == ShareSourceKey.person(11).encoded)
    }

    // MARK: - 削除の失敗を成功と誤認しない（レビュー指摘）

    /// ⚠️ バッチ自体が完了しても、エントリ単位で失敗する（権限不足など）。
    /// 全体成否だけ見て成功と誤認すると、記録を消してクラウドに管理不能なフォルダが残る。
    @Test("削除がエントリ単位で失敗したらセット記録を消さない")
    func failedDeleteKeepsSetRecord() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        // セット削除はフォルダ 1 件の削除。これを「消せない」失敗にする。
        await server.setFailDeletePaths([setFolder("Trip")])
        let setID = await store.allShareSets().first!.id
        #expect(await engine.deleteSet(id: setID) == false, "削除できていないのに成功を返した")
        #expect(await store.allShareSets().count == 1, "リモートに残っているのに記録を消した")
        #expect(await sharedFiles(server).count == 1)

        // 権限が戻れば、同じ操作で消える（再試行できる状態が保たれている）。
        await server.setFailDeletePaths([])
        #expect(await engine.deleteSet(id: setID))
        #expect(await store.allShareSets().isEmpty)
        #expect(await sharedFiles(server).isEmpty)
    }

    /// 「元から無い」失敗は目的達成なので成功に数える（掃除が永久に終わらなくなるのを防ぐ）。
    @Test("既に無いファイルの削除は成功として扱う")
    func deletingMissingFileCountsAsSuccess() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        // 共有側のファイルを外部から消しておく（＝削除要求は not_found になる）。
        let setID = await store.allShareSets().first!.id
        await server.remove("\(setFolder("Trip"))/a.jpg")
        #expect(await engine.removeItems(setID: setID, refKeys: ["L-a"]),
                "既に無いだけなのに失敗扱いになった")
        #expect(await store.shareItems(setID: setID).isEmpty, "記録が残ってしまった")
    }

    /// 単枚解除も同じ。消せなかった写真の記録を消すと、以後それを自分の持ち物として
    /// 認識できず、共有先に孤児ファイルが永久に残る。
    @Test("単枚解除で削除に失敗したら記録を残す（再試行できる）")
    func failedItemDeleteKeepsRecord() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await engine.syncNow()
        let setID = await store.allShareSets().first!.id

        await server.setFailDeletePaths(["\(setFolder("Trip"))/a.jpg"])
        #expect(await engine.removeItems(setID: setID, refKeys: ["L-a"]) == false)
        let refs = await store.shareItems(setID: setID).map(\.refKey)
        #expect(refs.sorted() == ["L-a", "L-b"], "消せていないのに記録を落とした: \(refs)")
        #expect(await sharedFiles(server).count == 2)
    }

    /// ⚠️ **クライアントがポーリングをやめても、サーバー側のコピージョブは止まらない**
    /// （Dropbox にジョブ取り消しの API は無い）。削除直後にジョブが完走すると、消した
    /// フォルダが復活し、記録は既に無いので誰も掃除できない孤児になる。
    @Test("削除後に復活した共有フォルダは次の反映で消し直される")
    func resurrectedFolderIsSweptOnNextSync() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA")])
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        let setID = await store.allShareSets().first!.id
        #expect(await engine.deleteSet(id: setID))
        #expect(await sharedFiles(server).isEmpty)

        // 遅れて完走したコピージョブがフォルダを作り直した状況を模す。
        await server.seed(setFolder("Trip"), hash: "", isFolder: true)
        await server.seed("\(setFolder("Trip"))/a.jpg", hash: "hA")

        // 別セットがあっても無くても、反映は墓標を掃除する。
        await engine.syncNow()
        let files = await sharedFiles(server)
        #expect(files.isEmpty, "復活したフォルダが残っている（誰の持ち物でもない孤児）: \(files)")
    }

    /// 反映中に削除しても、記録とクラウドが食い違わないこと。
    /// （反映がどこまで進んでいるかに依存するため、この 1 本だけでは回帰を捕まえきれない。
    /// 決定的な検証は上の「復活したフォルダの掃除」が担う。ここは**不変条件**
    /// ——「記録だけ消えてクラウドに残る」状態を作らない——を押さえる。）
    @Test("反映の実行中に削除しても、記録とクラウドが食い違わない")
    func deleteDuringSyncStaysConsistent() async {
        let (engine, store, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")])
        // 「サーバーでは完了するのにクライアントには終わらない」ジョブ＝長引く反映を作る。
        await server.setJobsTimeOutButComplete(true)
        engine.maxPollAttempts = 100_000        // 実質、止めない限り終わらない
        engine.pollIntervalNs = 1_000_000

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        let syncing = Task { await engine.syncNow() }
        // 反映がポーリングに入るまで待つ。
        while !engine.isSyncing { await Task.yield() }
        // 削除自身は普通に完了させる（コピーの待ちだけが残っている状況を作る）。
        await server.setJobsTimeOutButComplete(false)

        let setID = await store.allShareSets().first!.id
        let deleted = await engine.deleteSet(id: setID)
        _ = await syncing.value

        // 「消せた」なら記録もクラウドも空。「消せなかった」なら記録は残る。
        // どちらでもよいが、**記録だけ消えてクラウドに残る**のは駄目。
        let files = await sharedFiles(server)
        let sets = await store.allShareSets()
        #expect(deleted, "反映を止められず削除できなかった（キャンセルが効いていない）")
        #expect(sets.isEmpty == deleted, "削除の成否と記録の有無が食い違う")
        if sets.isEmpty {
            #expect(files.isEmpty, "記録を消したのに共有フォルダが残っている: \(files)")
        }
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

// MARK: - 墓標のアカウント分離・排他（再レビュー指摘）

/// ⚠️ 墓標をパスだけで持つと、猶予時間（15 分）の内に Dropbox アカウントを切り替えたとき、
/// **新しいアカウントの同名フォルダ**を消しに行く。共有ルートは既定値が同じなので普通に衝突する。
@Suite("共有の墓標（アカウント分離）")
struct ShareTombstoneAccountTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "tombstone-\(UUID().uuidString)") ?? .standard
    }

    @Test("別アカウントの墓標は見えない")
    func tombstonesAreScopedByAccount() {
        let d = defaults()
        let path = "/MosaicShare/iPhone-AAA/People-家族"
        ShareSettingsKeys.setDeletedFolderTombstones([path: Date()], account: "acct-a", d)

        #expect(ShareSettingsKeys.deletedFolderTombstones(account: "acct-a", d)[path] != nil)
        #expect(ShareSettingsKeys.deletedFolderTombstones(account: "acct-b", d).isEmpty,
                "別アカウントの同名フォルダを消しに行く")
    }

    @Test("片方のアカウントを更新しても、もう片方は消えない")
    func updatingOneAccountKeepsTheOther() {
        let d = defaults()
        ShareSettingsKeys.setDeletedFolderTombstones(["/a": Date()], account: "acct-a", d)
        ShareSettingsKeys.setDeletedFolderTombstones(["/b": Date()], account: "acct-b", d)
        ShareSettingsKeys.setDeletedFolderTombstones([:], account: "acct-a", d)   // a を掃除

        #expect(ShareSettingsKeys.deletedFolderTombstones(account: "acct-a", d).isEmpty)
        #expect(ShareSettingsKeys.deletedFileTombstones(account: "acct-b", d).isEmpty)
        #expect(ShareSettingsKeys.deletedFolderTombstones(account: "acct-b", d)["/b"] != nil,
                "他アカウントの墓標まで消している")
    }

    @Test("ファイル墓標もアカウントで分かれる")
    func fileTombstonesAreScoped() {
        let d = defaults()
        ShareSettingsKeys.setDeletedFileTombstones(["/x/a.jpg": Date()], account: "acct-a", d)
        #expect(ShareSettingsKeys.deletedFileTombstones(account: "acct-a", d).count == 1)
        #expect(ShareSettingsKeys.deletedFileTombstones(account: "acct-b", d).isEmpty)
    }
}

/// ⚠️ `updateSetMembers` だけが削除系の排他区間の外にあった。反映は先に読んだ計画でコピーするため、
/// 排他なしで除外すると「記録を消した後に旧計画がコピー」して孤児ファイルが残る。
@Suite("メンバー更新の排他", .serialized)
@MainActor
struct ShareMemberUpdateExclusionTests {

    /// ADR-175: 共有ルートはバックアップルート（`/MosaicPhotos`）の端末フォルダ配下 `Share/`。
    private static let backupRoot = "/MosaicPhotos"
    private static var shareRoot: String {
        BackupLayout.shareRoot(root: backupRoot, deviceFolder: BackupDeviceIdentity.currentFolderName())
    }

    private func makeStack() async -> (ShareSyncEngine, BackupStore, FakeDropboxServer) {
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        for (id, path, hash) in [("a", "/mosaicphotos/a.jpg", "hA"), ("b", "/mosaicphotos/b.jpg", "hB")] {
            await server.seed(path, hash: hash)
            await store.upsertRecord(dropboxPath: path, localIdentifier: id, filename: "\(id).jpg",
                                     creationDate: nil, contentHash: hash,
                                     people: [], albums: [], isFavorite: false)
        }
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(), storeProvider: { store },
                                     httpClient: server, defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        return (engine, store, server)
    }

    /// 反映（コピー）が走っている最中にメンバーを外すと、**記録を消した後に旧計画がコピー**して
    /// 孤児ファイルが残る。除外は削除系と同じ排他区間で行い、走行中の反映を止めてから進める。
    @Test("反映中のメンバー更新は、反映を止めてから進む")
    func memberUpdateStopsRunningSync() async {
        let (engine, store, server) = await makeStack()
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])
        await server.setJobsTimeOutButComplete(true)   // ジョブが終わらない＝反映が続く
        engine.maxPollAttempts = 100_000

        let syncing = Task { await engine.syncNow() }
        while !engine.isSyncing { await Task.yield() }

        let setID = await store.allShareSets().first!.id
        let result = await engine.updateSetMembers(setID: setID, refKeys: ["L-a"])

        // 除外が成立したなら、その時点で反映は止まっている（走らせたまま記録を消していない）。
        if result.removed > 0 {
            #expect(!engine.isSyncing,
                    "反映を走らせたままメンバーを外した（旧計画のコピーが孤児として残る）")
            let refs = await store.shareItems(setID: setID).map(\.refKey)
            #expect(refs == ["L-a"])
        } else {
            #expect(engine.lastError == .syncBusy, "諦めたのに理由が伝わらない")
        }

        await server.setJobsTimeOutButComplete(false)
        _ = await syncing.value
    }

    /// 未コピーの写真を外したときは、予定コピー先に墓標を置く（サーバー側ジョブ対策）。
    @Test("未コピー分を外すと、予定コピー先に墓標が残る")
    func removingUncopiedLeavesFileTombstone() async {
        let (engine, store, _) = await makeStack()
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "L-b"])   // まだ反映していない
        let setID = await store.allShareSets().first!.id

        _ = await engine.removeItems(setID: setID, refKeys: ["L-b"])

        let tombstones = engine.fileTombstonesForTesting()
        #expect(tombstones.keys.contains { $0.hasSuffix("/b.jpg") },
                "発行済みジョブが後から作るファイルを掃除できない: \(tombstones.keys)")
    }
}

// MARK: - 墓標は「不在を確認するまで」残す（ADR-172）

/// ⚠️ 発行済みの `copy_batch` は、クライアントが諦めてもサーバー側で走り続ける。
/// 猶予（15 分）で墓標を捨てると、その後にジョブが完走したとき
/// **外したはずの写真が共有フォルダに残り続ける**——記録には無いので以後どの反映でも掃除されない。
@Suite("共有の墓標（不在確認まで残す）")
@MainActor
struct ShareTombstoneRetentionTests {

    /// ADR-175: 共有ルートはバックアップルート（`/MosaicPhotos`）の端末フォルダ配下 `Share/`。
    private static let backupRoot = "/MosaicPhotos"
    private static var shareRoot: String {
        BackupLayout.shareRoot(root: backupRoot, deviceFolder: BackupDeviceIdentity.currentFolderName())
    }

    private func makeStack() async -> (ShareSyncEngine, BackupStore, FakeDropboxServer, UserDefaults) {
        let defaults = isolatedShareDefaults()
        defaults.set(true, forKey: ShareSettingsKeys.provideEnabled)
        defaults.set(Self.backupRoot, forKey: BackupSettingsKeys.dropboxFolder)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let server = FakeDropboxServer()
        await server.seed("/mosaicphotos/a.jpg", hash: "hA")
        await store.upsertRecord(dropboxPath: "/mosaicphotos/a.jpg", localIdentifier: "a",
                                 filename: "a.jpg", creationDate: nil, contentHash: "hA",
                                 people: [], albums: [], isFavorite: false)
        let engine = ShareSyncEngine(tokenProvider: FakeTokenProvider(),
                                     storeProvider: { store }, httpClient: server,
                                     defaults: defaults)
        engine.pollIntervalNs = 1_000_000
        engine.maxPollAttempts = 3
        return (engine, store, server, defaults)
    }

    private func tombstones(_ defaults: UserDefaults) -> [String: Date] {
        ShareSettingsKeys.deletedFileTombstones(account: nil, defaults)
    }

    /// 本命。猶予を過ぎていても、**実在を確認できないうちは墓標を残す**。
    @Test("猶予を過ぎても、まだ在るなら墓標を消さない")
    func keepsTombstoneWhileFileExists() async {
        let (engine, _, server, defaults) = await makeStack()
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        // 外した写真の予定コピー先に、猶予をとうに過ぎた墓標を置く。
        let folder = SharePlanning.setFolderPath(
            shareRoot: Self.shareRoot, folderName: ShareNaming.folderName("Trip", kind: nil),
            deviceFolder: nil)!.lowercased()   // shareRoot は端末フォルダ込み（ADR-175）
        let ghost = "\(folder)/ghost.jpg"
        let old = Date().addingTimeInterval(-ShareSettingsKeys.deletedFolderGraceSeconds * 4)
        ShareSettingsKeys.setDeletedFileTombstones([ghost: old], account: nil, defaults)
        // 遅れてきたコピージョブが作ったファイル（削除できない設定にして「残る」を再現）。
        await server.seed(ghost, hash: "hGhost")
        await server.setFailDeletePaths([ghost])

        await engine.syncNow()
        #expect(tombstones(defaults)[ghost] != nil,
                "まだ在るのに墓標を捨てた（この写真は以後どの反映でも掃除されない）")
    }

    @Test("不在を確認できたら墓標を消す")
    func dropsTombstoneOnceGone() async {
        let (engine, _, server, defaults) = await makeStack()
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let folder = SharePlanning.setFolderPath(
            shareRoot: Self.shareRoot, folderName: ShareNaming.folderName("Trip", kind: nil),
            deviceFolder: nil)!.lowercased()   // shareRoot は端末フォルダ込み（ADR-175）
        let ghost = "\(folder)/ghost.jpg"
        ShareSettingsKeys.setDeletedFileTombstones([ghost: Date()], account: nil, defaults)
        await server.seed(ghost, hash: "hGhost")   // 削除は成功する（failDeletePaths を設定しない）

        await engine.syncNow()
        #expect(await server.filePaths().contains(ghost) == false, "fixture: 削除できていない")
        #expect(tombstones(defaults)[ghost] == nil, "不在を確認したのに墓標が残っている")
    }
}
