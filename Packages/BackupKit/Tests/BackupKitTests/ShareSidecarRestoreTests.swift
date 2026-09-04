import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// 解析サイドカー（`.mosaic-share/analysis-v1.json`）の**復元**（ADR-166）。
///
/// ⚠️ 以前はアップロードの要否を「中身が変わったか」だけで決めていた。そのため誰かが
/// Dropbox 上の `.mosaic-share` を消すと、**写真は自己修復されるのに解析結果だけ永久に戻らない**。
/// 受信側は自前で解析し直すので画面上は壊れて見えず、気づきにくい形の欠落だった。
///
/// ここで固定するのは 3 つ:
/// 1. 消えたら復元する
/// 2. 在るなら**アップロードし直さない**（毎回上げると数 MB を無駄に往復する）
/// 3. 中身が変われば当然上げ直す
@Suite("サイドカーの復元")
@MainActor
struct ShareSidecarRestoreTests {

    private static let backupRoot = "/MosaicPhotos"
    private static var shareRoot: String {
        BackupLayout.shareRoot(root: backupRoot, deviceFolder: BackupDeviceIdentity.currentFolderName())
    }

    /// 固定の解析結果を返すスタブ。`entries` を差し替えると「解析が進んだ」状況を作れる。
    private final class StubAnalysis: ShareAnalysisSource {
        var tags: [String]
        init(tags: [String]) { self.tags = tags }
        func analysisEntries(forRefKeys refKeys: [String]) async
            -> (versions: ShareSidecar.Versions, entries: [String: ShareSidecar.Entry]) {
            var entries: [String: ShareSidecar.Entry] = [:]
            for key in refKeys { entries[key] = ShareSidecar.Entry(tags: tags) }
            return (ShareSidecar.Versions(tag: 1, perception: 1, face: 1), entries)
        }
    }

    private func makeStack(analysis: ShareAnalysisSource)
        async -> (engine: ShareSyncEngine, server: FakeDropboxServer) {
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
        engine.analysisSource = analysis
        return (engine, server)
    }

    /// サイドカーの実パス（セットフォルダ配下・小文字）。
    private func sidecarPath(_ name: String) -> String {
        let folder = SharePlanning.setFolderPath(
            shareRoot: Self.shareRoot, folderName: ShareNaming.folderName(name, kind: nil),
            deviceFolder: nil)!   // shareRoot は端末フォルダ込み（ADR-175）
        return ShareSidecar.sidecarPath(setFolderPath: folder).lowercased()
    }

    private func sidecarExists(_ server: FakeDropboxServer, _ name: String) async -> Bool {
        await server.filePaths().contains(sidecarPath(name))
    }

    @Test("初回の反映でサイドカーが作られる")
    func sidecarIsCreated() async {
        let stub = StubAnalysis(tags: ["beach"])
        let (engine, server) = await makeStack(analysis: stub)
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        #expect(await sidecarExists(server, "Trip"), "サイドカーが作られていない")
    }

    /// ⚠️ 本命。外部（Dropbox の Web UI・他端末）から消された状況を作り、次の反映で戻ることを見る。
    @Test("外部から消されたサイドカーは次の反映で復元される")
    func deletedSidecarIsRestored() async {
        let stub = StubAnalysis(tags: ["beach"])
        let (engine, server) = await makeStack(analysis: stub)
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        #expect(await sidecarExists(server, "Trip"), "fixture: 先にサイドカーが無い")

        // 外部削除（中身は変えていないので、旧実装ではチェックサム一致で上げ直されない）。
        await server.remove(sidecarPath("Trip"))
        #expect(await sidecarExists(server, "Trip") == false, "fixture: 削除できていない")

        await engine.syncNow()
        #expect(await sidecarExists(server, "Trip"),
                "消えたサイドカーが復元されていない（解析結果だけ永久に失われる）")
    }

    /// 実在確認のために毎回上げ直しては、数 MB を無駄に往復することになる。
    @Test("在るなら再アップロードしない")
    func doesNotReuploadWhenPresent() async {
        let stub = StubAnalysis(tags: ["beach"])
        let (engine, server) = await makeStack(analysis: stub)
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()

        let uploadsAfterFirst = await server.uploadCount()
        #expect(uploadsAfterFirst >= 1, "fixture: 初回のアップロードが記録されていない")

        await engine.syncNow()
        await engine.syncNow()
        #expect(await server.uploadCount() == uploadsAfterFirst,
                "中身も実在も変わっていないのに上げ直している")
    }

    @Test("中身が変わったら上げ直す")
    func reuploadsWhenContentChanges() async {
        let stub = StubAnalysis(tags: ["beach"])
        let (engine, server) = await makeStack(analysis: stub)
        _ = await engine.createSet(name: "Trip", refKeys: ["L-a"])
        await engine.syncNow()
        let uploadsAfterFirst = await server.uploadCount()

        stub.tags = ["beach", "sunset"]   // 解析が進んだ
        await engine.syncNow()
        #expect(await server.uploadCount() > uploadsAfterFirst,
                "解析が進んだのにサイドカーが更新されていない")
    }
}
