import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// **配線が生きているか**（ADR-202）。
///
/// 検知（`missingOffloadedPaths`）も停止（`OffloadHalt.record`）も部品としては試してある。
/// しかし**照合がそれを呼んでいなければ、機能はまるごと死んでいる**——このプロジェクトが
/// 何度も踏んだ形（「直したはずが画面に届いていない」）。部品ではなく、
/// `reconcileWithDropbox` を実際に走らせて確かめる。
///
/// ⚠️ 台帳は**差し替えた**インメモリのものを使う（差し替えられないと、このテストが
/// 実機の台帳を書いてしまう）。
@Suite("緊急停止の配線（照合 → 検知 → 停止）", .serialized)
@MainActor
struct OffloadHaltWiringTests {

    private let root = "/MosaicPhotos"
    /// ⚠️ **実際の端末フォルダ名から組み立てる**。決め打ちのパスにすると、印の書き先が
    /// 「管轄外」と判定されて再送が 0 件になる——その判定自体が正しいので、
    /// テストの前提の方を本物に合わせる。
    private var backupRoot: String { BackupEngine.deviceBackupRoot(for: root) }
    private let photo = Data("only-copy".utf8)

    private func makeEngine(_ server: FakeDropboxServer,
                            store: BackupStore) -> BackupEngine {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        // ⚠️ `auth.credential` は外から差せない（internal(set)）ので、トークンだけ差し替える。
        return BackupEngine(auth: auth, httpClient: server, store: store,
                            tokenProvider: FakeTokenProvider())
    }

    /// 照合が見る場所（設定のバックアップルート）を、このテストの root に揃える。
    private func withBackupFolder(_ body: () async -> Void) async {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: BackupSettingsKeys.dropboxFolder)
        defaults.set(root, forKey: BackupSettingsKeys.dropboxFolder)
        OffloadHalt.resetForTesting()
        defaults.set(500, forKey: BackupSettingsKeys.offloadAutoThresholdMB)
        await body()
        OffloadHalt.resetForTesting()
        defaults.removeObject(forKey: BackupSettingsKeys.offloadAutoThresholdMB)
        if let previous { defaults.set(previous, forKey: BackupSettingsKeys.dropboxFolder) }
        else { defaults.removeObject(forKey: BackupSettingsKeys.dropboxFolder) }
    }

    /// オフロード済み 1 枚ぶんの台帳と、Dropbox 上の実体を用意する。
    private func prepared(_ server: FakeDropboxServer) async -> (BackupStore, String) {
        await server.seed(root, hash: "", isFolder: true)
        let path = "\(backupRoot)/2023/2023-11/a.jpg"
        await server.upload(path: path, data: photo)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        _ = await store.upsertOffloads([(localIdentifier: "ID-a", dropboxPath: path,
                                         albums: ["旅行"],
                                         captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                                         contentHash: DropboxContentHash.hash(of: photo))])
        return (store, path)
    }

    @Test("実体が消えていたら、照合がオフロードを止めて知らせを作る")
    func reconcileHaltsWhenTheOnlyCopyIsGone() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, path) = await prepared(server)
            let engine = makeEngine(server, store: store)

            // 利用者が Dropbox の Web でそのファイルを消した（唯一のコピーが失われる）。
            await server.remove(path)
            let result = await engine.reconcileWithDropbox()

            #expect(result != nil, "照合そのものが走っていない")
            #expect(engine.offloadHalt?.missingCount == 1,
                    """
                    照合が検知・停止を呼んでいない＝機能がまるごと死んでいる。
                    （部品単位のテストは通るので、配線を通しで見ないと気づけない）
                    """)
            #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.offloadAutoThresholdMB) == 0,
                    "自動オフロードが止まっていない")
        }
    }

    /// ⚠️ **誤発動しないこと**。設定を勝手に変える処理なので、こちらの方が大事。
    @Test("実体が在るなら、照合は何も止めない")
    func reconcileDoesNotHaltWhenEverythingIsThere() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, _) = await prepared(server)
            let engine = makeEngine(server, store: store)

            let result = await engine.reconcileWithDropbox()

            #expect(result != nil, "照合そのものが走っていない")
            #expect(engine.offloadHalt == nil, "在る写真を消えたと判定して停止した（誤発動）")
            #expect(UserDefaults.standard.integer(forKey: BackupSettingsKeys.offloadAutoThresholdMB) == 500,
                    "何も起きていないのに設定を書き換えた")
        }
    }

    // MARK: - 台帳の建て直しと、印の再送（どちらもエンジン側の配線）

    /// ⚠️ **既に台帳があるなら建て直さない**。実端末の台帳が正で、クラウドの印は
    /// 「無くしたときの控え」でしかない。上書きすると、端末で直した内容を捨てることになる。
    @Test("台帳が空のときだけ、印から建て直す")
    func rebuildOnlyWhenTheLedgerIsEmpty() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, path) = await prepared(server)
            let engine = makeEngine(server, store: store)
            let metadata = DropboxBackupMetadata(entries: [
                "\(backupRoot)/2023/2023-11/other.jpg".lowercased(): DropboxBackupMetadata.Entry(
                    people: [], albums: ["旅行"], localIdentifier: "ID-other",
                    offloadedAt: "2026-09-01T00:00:00Z")])

            // (1) 台帳には既に 1 件ある（`prepared` が入れた）＝建て直さない。
            await engine.rebuildOffloadLedgerIfEmpty(from: metadata)
            var snapshot = await store.offloadLedgerSnapshot()
            #expect(snapshot.count == 1, "台帳が在るのに印で上書きした（端末側の記録を失う）")

            // (2) 台帳を空にすると、印から建て直す。
            await store.removeOffloads(localIdentifiers: ["ID-a"])
            await engine.reloadOffloadLedger()
            await engine.rebuildOffloadLedgerIfEmpty(from: metadata)
            snapshot = await store.offloadLedgerSnapshot()
            #expect(snapshot.count == 1, "空の台帳を印から建て直していない")
            #expect(snapshot.byAlbum.values.flatMap { $0 }
                        .contains("\(backupRoot)/2023/2023-11/other.jpg".lowercased()),
                    "建て直した中身が印と違う")
            _ = path
        }
    }

    /// 未送信の印は、**台帳を出典に**再送される（写真はもう端末に無いので候補走査には現れない）。
    @Test("未送信の印は、台帳から再送されて送信済みになる")
    func pendingMarkersAreResentFromTheLedger() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, _) = await prepared(server)
            let engine = makeEngine(server, store: store)
            #expect(await store.offloadsPendingMarker().count == 1, "前提: 未送信が 1 件")

            let sent = await engine.retryPendingOffloadMarkers()

            #expect(sent == 1, "台帳を出典に再送できていない")
            #expect(await store.offloadsPendingMarker().isEmpty, "送れたのに未送信のまま")
        }
    }

    /// 書けなかった回は**未送信のまま**残る（送信済みにすると二度と再送されない）。
    @Test("再送に失敗したら、未送信のまま残る")
    func failedResendStaysPending() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, _) = await prepared(server)
            await server.failUploads(matching: ".mosaic", status: 403)
            let engine = makeEngine(server, store: store)

            let sent = await engine.retryPendingOffloadMarkers()

            #expect(sent == 0, "書けていないのに送信済みにした")
            #expect(await store.offloadsPendingMarker().count == 1, "未送信の記録が消えた")
        }
    }

    /// ⚠️ **一覧が取れなかった回は判定しない**。部分的な一覧で判定すると、実在する写真を
    /// 「消えた」と読んで緊急停止が誤発動する（`listFolder` は部分結果を返さない設計）。
    @Test("一覧が途中で失敗した回は、照合ごと見送る（停止しない）")
    func incompleteListingNeverHalts() async {
        await withBackupFolder {
            let server = FakeDropboxServer()
            let (store, _) = await prepared(server)
            await server.setPageSize(1)
            await server.setFailListFolderContinue(true)
            let engine = makeEngine(server, store: store)

            let result = await engine.reconcileWithDropbox()

            #expect(result == nil, "不完全な一覧で照合を続けている")
            #expect(engine.offloadHalt == nil, "不完全な一覧で緊急停止が誤発動した")
        }
    }
}
