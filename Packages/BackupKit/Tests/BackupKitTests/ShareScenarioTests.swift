import Foundation
import Testing
@testable import BackupKit
import DropboxCore

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
        UserDefaults.standard.set(true, forKey: ShareSettingsKeys.provideEnabled)
        UserDefaults.standard.set(Self.shareRoot, forKey: ShareSettingsKeys.shareRootFolder)

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
                                     storeProvider: { store }, httpClient: server)
        // ジョブのポーリングはテストでは即座に打ち切る（本番は 0.5s × 480＝4 分）。
        engine.pollIntervalNs = 1_000_000     // 1ms
        engine.maxPollAttempts = 3
        return (engine, store, server)
    }

    /// 共有フォルダ内のファイル（フォルダを除く）。
    private func sharedFiles(_ server: FakeDropboxServer) async -> [String] {
        await server.filePaths().filter { $0.hasPrefix(Self.shareRoot.lowercased() + "/") }
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
        await server.seed("/mosaicshare/trip", hash: "", isFolder: true)
        await server.seed("/mosaicshare/trip/img.jpg", hash: "hSAME")
        await server.seed("/mosaicshare/trip/img (1).jpg", hash: "hSAME")

        // 未コピーのアイテムを 1 つ作り、そのコピーを必ず失敗させる。
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a", "C-/other/x.jpg"])
        await server.setFailCopyPaths(["/mosaicshare/trip/x.jpg"])

        await engine.syncNow()
        let files = await sharedFiles(server)
        #expect(files.contains("/mosaicshare/trip/img (1).jpg"),
                "コピー失敗の回に掃除が走った（空回りループの入口）: \(files)")
    }

    @Test("コピーが完全に成功した回は重複を掃除する")
    func cleansDuplicatesOnSuccessfulRun() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/img.jpg", "hSAME")])
        await server.seed("/mosaicshare/trip", hash: "", isFolder: true)
        await server.seed("/mosaicshare/trip/img.jpg", hash: "hSAME")
        await server.seed("/mosaicshare/trip/img (1).jpg", hash: "hSAME")

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(!files.contains("/mosaicshare/trip/img (1).jpg"), "重複が掃除されない: \(files)")
        #expect(files.contains("/mosaicshare/trip/img.jpg"), "正規ファイルまで消えた: \(files)")
    }

    /// 中身の違う「(1)」付きファイルは消してはいけない（ユーザーの写真）。
    @Test("中身の違う (N) 形式ファイルは掃除しない")
    func keepsDistinctFileNamedLikeDuplicate() async {
        let (engine, _, server) = await makeStack(backup: [
            ("a", "/mosaicphotos/img.jpg", "hA")])
        await server.seed("/mosaicshare/trip", hash: "", isFolder: true)
        await server.seed("/mosaicshare/trip/img.jpg", hash: "hA")
        await server.seed("/mosaicshare/trip/img (1).jpg", hash: "hDIFFERENT")

        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let files = await sharedFiles(server)
        #expect(files.contains("/mosaicshare/trip/img (1).jpg"),
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
        await server.seed("/mosaicshare/trip/a.jpg", hash: "hA")   // 念のため存在確認
        _ = try? await server.data(for: deleteRequest(path: "/mosaicshare/trip/a.jpg"))
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
        #expect(files == ["/mosaicshare/trip/b.jpg"], "解除の結果が想定と違う: \(files)")
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
        #expect(!files.contains { $0.contains("group 2/") }, "フォルダが 2 つできた: \(files)")
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
        #expect(files == ["/mosaicshare/trip/a.jpg"], "外れた写真が残っている: \(files)")
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
        #expect(files == ["/mosaicshare/trip/a.jpg"])
        let setID = await store.allShareSets()[0].id
        let items = await store.shareItems(setID: setID)
        #expect(items.first { $0.refKey == "L-missing" }?.state == .waitingBackup,
                "未バックアップが waitingBackup になっていない")
    }
}
