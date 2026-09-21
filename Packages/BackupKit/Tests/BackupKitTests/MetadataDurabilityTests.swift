import DropboxCore
import DropboxTestSupport
import Foundation
import Photos
import Testing
@testable import BackupKit

/// ⚠️ メタデータ（人物名・アルバム・位置情報）は写真の実体と違い、**失敗しても次回の対象に
/// ならない**。実体を上げた時点で写真 ID は台帳と SwiftData に記録され、以後 pending に
/// 入らないため。したがって「取得失敗を空として上書き」も「送信失敗の握り潰し」も、
/// そのまま**永久の欠落**になる（レビュー指摘）。
@Suite("Backup metadata durability")
struct MetadataDurabilityTests {

    /// 応答をパスごとに差し替えられる偽 Dropbox。

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], localIdentifier: "id")
    }

    // MARK: - 取得失敗を「空」と読まない

    @Test("既存シャードの取得に失敗したら、そのシャードは書かない")
    func failedDownloadSkipsWrite() async {
        // 認証切れ（401）。「無い」ではないので、既存を空で上書きしてはいけない。
        let server = FakeDropboxServer()
        await server.failDownloads(matching: "meta/2025-08.json", status: 401)
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let result = await writer.apply(byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], facts: nil) { _ in }

        #expect(await server.uploadCount() == 0, "取得できていないのに上書きした（既存が消える）")
        #expect(result.written.isEmpty)
        #expect(result.failed["2025-08"] != nil, "再送のために失敗分を返していない")
    }

    @Test("ファイルが無い（not_found）ときは新規シャードとして書く")
    func notFoundCreatesNewShard() async {
        let server = FakeDropboxServer()   // 何も置かない＝そのシャードは存在しない
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let result = await writer.apply(byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], facts: nil) { _ in }

        #expect(result.written == ["2025-08"], "新規作成できていない")
        let written = await server.body(at: "/b/.mosaic/meta/2025-08.json")
        #expect(String(decoding: written ?? Data(), as: UTF8.self).contains("太郎"))
    }

    @Test("送信に失敗したシャードは失敗として返る（再送の材料）")
    func failedUploadIsReported() async {
        let server = FakeDropboxServer()
        // ⚠️ 403（権限）を使う。429・5xx は `uploadJSONResult` が自力で 3 回やり直すので、
        // 「1 回で失敗して終わる」状況にならずテストが数秒待つことになる。
        await server.failUploads(matching: ".mosaic", status: 403)
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let result = await writer.apply(byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], facts: nil) { _ in }

        #expect(result.written.isEmpty)
        #expect(result.failed["2025-08"]?.count == 1)
    }

    @Test("送信に失敗した部分更新（マーカー）は false を返す（送信済みにしない）")
    func failedMarkerUpdateIsReported() async {
        let server = FakeDropboxServer()
        // ⚠️ 403（権限）を使う。429・5xx は `uploadJSONResult` が自力で 3 回やり直すので、
        // 「1 回で失敗して終わる」状況にならずテストが数秒待つことになる。
        await server.failUploads(matching: ".mosaic", status: 403)
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let ok = await writer.mark(paths: ["/b/a.jpg"], shard: "2025-08",
            mutate: { $0.offloadedAt = "2026-08-26T00:00:00Z" },
            makeDefault: { _ in DropboxBackupMetadata.Entry(people: [], albums: [],
                                                            localIdentifier: "off-1") },
            log: { _ in })

        #expect(!ok, "書けていないのに成功を返すと、台帳に送信済みの印が付いて再送されない")
    }

    // MARK: - オフロードの印は、あとから来たバックアップのエントリに消されない

    /// ⚠️ 印（`offloadedAt` / `verifiedAt`）は「アプリが端末の原本を消した」という**起きた事実**で、
    /// 再インストール後に台帳を建て直す唯一の手掛かり。バックアップ側が作るエントリは
    /// 印の存在を知らない（常に nil）ので、素朴に上書きすると、再送キューに残っていた古い
    /// エントリが 1 枚流れただけで印が消え、**ユーザーが写真アプリで消した写真と区別できなく**
    /// なる＝二度と復元できない（ADR-200）。
    @Test("あとから来たバックアップのエントリは、オフロードの印を消さない")
    func laterBackupEntryKeepsTheOffloadMarker() async {
        let marked = DropboxBackupMetadata(entries: [
            "/b/a.jpg": DropboxBackupMetadata.Entry(people: [], albums: [], localIdentifier: "a",
                                                    verifiedAt: "2026-09-01T00:00:00Z",
                                                    offloadedAt: "2026-09-01T00:00:00Z")])
        let existing = try! JSONEncoder().encode(marked)
        let server = FakeDropboxServer()
        await server.upload(path: "/b/.mosaic/meta/2025-08.json", data: existing)
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        // 再送キューに残っていた（印を知らない）バックアップのエントリが流れる。
        _ = await writer.apply(byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]],
                               facts: nil) { _ in }

        let body = String(decoding: await server.body(at: "/b/.mosaic/meta/2025-08.json") ?? Data(),
                          as: UTF8.self)
        let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: Data(body.utf8))
        #expect(decoded?.entries["/b/a.jpg"]?.people == ["太郎"], "新しい内容が反映されていない")
        #expect(decoded?.entries["/b/a.jpg"]?.offloadedAt != nil,
                "オフロードの印が消えた（その写真は二度と復元できない）")
        #expect(decoded?.entries["/b/a.jpg"]?.verifiedAt != nil, "検証済みの印が消えた")
    }

    // MARK: - 「取れたが読めない」を「無い」と読まない（レビュー指摘）

    /// ⚠️ HTTP 200 で返ってきた既存 JSON がデコード不能なとき、空として上書きすると
    /// その月の人物名・アルバム・位置情報・オフロードマーカーが丸ごと消える。
    /// 端末を消すと再生成できない情報なので、**書かずに失敗として残す**（次回再送）。
    @Test("既存シャードが読めない JSON なら、そのシャードは書かない（再送に残す）")
    func unreadableShardSkipsWrite() async {
        let server = FakeDropboxServer()
        await server.upload(path: "/b/.mosaic/meta/2025-08.json", data: Data(("{ this is not valid json").utf8))
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let result = await writer.apply(byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], facts: nil) { _ in }

        #expect(await server.uploadCount() == 0, "読めていないのに空から上書きした（既存が消える）")
        #expect(result.written.isEmpty, "デコード不能を新規ファイルの不在と同じ成功経路にしている")
        #expect(result.failed["2025-08"] != nil, "再送のために失敗分を返していない")
    }

    @Test("マーカー更新も、既存シャードが読めない JSON なら書かず false を返す")
    func unreadableShardSkipsMarkerUpdate() async {
        let server = FakeDropboxServer()
        await server.upload(path: "/b/.mosaic/meta/2025-08.json", data: Data((#"{"entries": [broken"#).utf8))
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: "/b")

        let ok = await writer.mark(paths: ["/b/a.jpg"], shard: "2025-08",
            mutate: { $0.offloadedAt = "2026-08-26T00:00:00Z" },
            makeDefault: { _ in DropboxBackupMetadata.Entry(people: [], albums: [],
                                                            localIdentifier: "off-1") },
            log: { _ in })

        #expect(!ok, "書けていないのに成功を返すと、台帳に送信済みの印が付いて再送されない")
        #expect(await server.uploadCount() == 0, "既存のマーカーごと空で上書きした")
    }

    // MARK: - 並行するシャード更新（レビュー指摘）

    /// **状態を持つ**偽 Dropbox。アップロードされた JSON を保持し、以後の download がそれを返す。
    /// download に人工的な遅延を入れ、read-modify-write の競合を確実に作る。

    @Test("同じシャードへのバックアップ追記とオフロードマーカー更新が並行しても、両方が残る")
    func concurrentShardUpdatesKeepBothChanges() async {
        // ⚠️ 直列化していないと、後着の overwrite が先着の変更を消す。消えたのがマーカーだと
        // 台帳は「送信済み」なので再送されず、再インストール後に台帳を再構築できない。
        let folder = "/concurrent"
        let shardPath = folder + BackupMetadataV2.shardSuffix("2025-08")
        let server = FakeDropboxServer()
        let writer = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t", root: folder)

        async let backup = writer.apply(
            byShard: ["2025-08": ["\(folder)/new.jpg": entry(["太郎"])]], facts: nil) { _ in }
        async let marker = writer.mark(
            paths: ["\(folder)/offloaded.jpg"], shard: "2025-08",
            mutate: { $0.offloadedAt = "2026-08-26T00:00:00Z" },
            makeDefault: { _ in DropboxBackupMetadata.Entry(people: [], albums: [],
                                                            localIdentifier: "off-1") },
            log: { _ in })
        let applied = await backup
        let markerOK = await marker

        #expect(applied.written == ["2025-08"])
        #expect(markerOK)
        let final = await server.body(at: shardPath) ?? Data()
        let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: final)
        #expect(decoded?.entries["\(folder)/new.jpg"]?.people == ["太郎"],
                "バックアップの追記が並行するマーカー更新に消された")
        #expect(decoded?.entries["\(folder)/offloaded.jpg"]?.offloadedAt != nil,
                "オフロードマーカーが並行するバックアップ追記に消された（再送もされない）")
    }

    // MARK: - 再送キュー

    @Test("保留分と今回分は統合され、同じパスは新しい値が勝つ")
    func pendingMergesWithNew() {
        let pending: PendingMetadataStore.Payload = [
            "2025-08": ["/b/a.jpg": entry(["旧"]), "/b/b.jpg": entry(["残す"])]]
        let adding: PendingMetadataStore.Payload = [
            "2025-08": ["/b/a.jpg": entry(["新"])],
            "2025-09": ["/b/c.jpg": entry(["別月"])]]

        let merged = PendingMetadataStore.merged(pending: pending, adding: adding)
        #expect(merged["2025-08"]?["/b/a.jpg"]?.people == ["新"])
        #expect(merged["2025-08"]?["/b/b.jpg"]?.people == ["残す"], "保留分を落とした")
        #expect(merged["2025-09"]?.count == 1)
        #expect(PendingMetadataStore.entryCount(merged) == 3)
    }

    @Test("再送キューはディスクに永続する（アプリを終了しても失われない）")
    func pendingSurvivesRoundTrip() {
        let name = "BackupPendingMetadataTest-\(UUID().uuidString).json"
        let store = PendingMetadataStore(filename: name)
        defer { store.save([:]) }   // 後片付け（空保存＝ファイル削除）

        store.save(["2025-08": ["/b/a.jpg": entry(["太郎"])]])
        let reloaded = PendingMetadataStore(filename: name).load()
        #expect(reloaded["2025-08"]?["/b/a.jpg"]?.people == ["太郎"])

        store.save([:])
        #expect(PendingMetadataStore(filename: name).load().isEmpty, "空保存で消えていない")
    }
}

// MARK: - 実行世代（キャンセル直後の再実行・レビュー指摘）

/// ⚠️ `cancel()` は旧タスクの終了を待たずに次の実行を始められる。旧タスクは自分が現行だと
/// 思ったまま `phase` を更新し、終了時に `backupTask = nil` を書く——**新しい実行の
/// ハンドルまで消えてキャンセルできなくなる**。世代で弾くこと。
@Suite("Backup run generation")
@MainActor
struct BackupRunGenerationTests {

    @Test("キャンセルすると、旧世代は現行ではなくなる")
    func cancelInvalidatesOldGeneration() {
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        let old = engine.beginRunGenerationForTesting()
        #expect(engine.isCurrentRun(old))

        engine.cancel()
        #expect(!engine.isCurrentRun(old), "キャンセル後も旧タスクの更新が通ってしまう")
    }

    @Test("再実行すると旧世代は無効になり、新世代だけが現行になる")
    func restartSupersedesOldGeneration() {
        let engine = BackupEngine(auth: DropboxAuthService(appKey: "k", redirectURI: "app://cb"))
        let first = engine.beginRunGenerationForTesting()
        engine.cancel()
        let second = engine.beginRunGenerationForTesting()

        #expect(!engine.isCurrentRun(first), "旧タスクが新しい実行を上書きし得る")
        #expect(engine.isCurrentRun(second))
    }
}

// MARK: - 再送キューの保存失敗（レビュー指摘）

/// ⚠️ 写真本体は進捗台帳に載って次回の対象から外れる。送信に失敗し、さらに再送キューへの
/// 保存にも失敗すると、人物・アルバム・位置情報は**永久に欠落**する。黙って成功にしない。
@Suite("PendingMetadataStore durability")
struct PendingMetadataDurabilityTests {

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], localIdentifier: "id")
    }

    @Test("保存できたら true")
    func reportsSuccess() {
        let name = "PendingMetaTest-\(UUID().uuidString).json"
        let store = PendingMetadataStore(filename: name)
        defer { _ = store.save([:]) }
        #expect(store.save(["2025-08": ["/b/a.jpg": entry(["太郎"])]]))
    }

    @Test("空保存（キュー解消）も成功として返る")
    func clearingEmptyQueueSucceeds() {
        let name = "PendingMetaTest-\(UUID().uuidString).json"
        let store = PendingMetadataStore(filename: name)
        #expect(store.save([:]), "まだファイルが無いだけで失敗にしない")
        _ = store.save(["2025-08": ["/b/a.jpg": entry(["太郎"])]])
        #expect(store.save([:]))
        #expect(store.load().isEmpty)
    }

    @Test("書けない場所なら false を返す（黙って成功にしない）")
    func reportsFailure() {
        // ディレクトリとして使えない名前（既存ファイルの配下）を指す。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("pendingmeta-\(UUID().uuidString)")
        try? Data("blocker".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = PendingMetadataStore(directory: base.appendingPathComponent("sub", isDirectory: true),
                                         filename: "queue.json")
        #expect(!store.save(["2025-08": ["/b/a.jpg": entry(["太郎"])]]),
                "保存できていないのに成功を返すと、欠落が黙って確定する")
    }
}

// MARK: - アップロード記録の確定（レビュー指摘）

/// ⚠️ 記録の保存を fire-and-forget にすると、大量アップロード後や BGTask 終了時に保存タスクが
/// 残ったままアプリが止まり、**進捗台帳には載っているのに SwiftData 記録が無い**写真ができる。
/// その写真はオフロード・アルバム・共有のどれからも辿れない。
@Suite("Backup record commit")
struct BackupRecordCommitTests {

    @Test("保存できたら true（進捗台帳へ入れてよい）")
    func reportsSuccess() async {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let saved = await store.upsertRecord(
            dropboxPath: "/b/a.jpg", localIdentifier: "id-a", filename: "a.jpg",
            creationDate: nil, contentHash: "hA", people: [], albums: [], isFavorite: false)
        #expect(saved)
        #expect(await store.allRecordsLite().count == 1)
    }

    @Test("同じパスの再アップロードは上書きで 1 件のまま")
    func upsertIsIdempotent() async {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        for hash in ["h1", "h2"] {
            _ = await store.upsertRecord(
                dropboxPath: "/b/a.jpg", localIdentifier: "id-a", filename: "a.jpg",
                creationDate: nil, contentHash: hash, people: [], albums: [], isFavorite: false)
        }
        let records = await store.allRecordsLite()
        #expect(records.count == 1)
        #expect(records.first?.contentHash == "h2")
    }

    // MARK: - 削除 → 再取り込み（localIdentifier の付け替え・レビュー指摘）

    /// ⚠️ 端末から削除して同じ写真を再取り込みすると localIdentifier が変わる。実体は同じなので
    /// 409→hash 一致で「済み」扱いになり `upsertRecord` の**既存分岐**へ来るが、そこで
    /// localIdentifier を据え置くと記録は**消えた旧 ID**を指したまま残る。runner は新 ID を
    /// 進捗台帳へ入れるので以後 pending にも入らず、自己修復しない。
    private func reimported() async -> BackupStore {
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        // 1 回目: 旧 ID でバックアップ。
        _ = await store.upsertRecord(
            dropboxPath: "/b/IMG_0001.HEIC", localIdentifier: "OLD-ID", filename: "IMG_0001.HEIC",
            creationDate: Date(timeIntervalSince1970: 1_600_000_000), contentHash: "hA",
            people: [], albums: [], isFavorite: false)
        // 2 回目: 削除→再取り込み後。同じパス・同じ hash（409 の hash 一致経路）で新 ID。
        _ = await store.upsertRecord(
            dropboxPath: "/b/IMG_0001.HEIC", localIdentifier: "NEW-ID", filename: "IMG_0001.HEIC",
            creationDate: Date(timeIntervalSince1970: 1_600_000_000), contentHash: "hA",
            people: [], albums: [], isFavorite: false)
        return store
    }

    @Test("再取り込みの記録は現在の localIdentifier を指し、重複もしない")
    func reimportRebindsRecordToCurrentAsset() async {
        let store = await reimported()
        let records = await store.allRecordsLite()
        #expect(records.count == 1, "同じ Dropbox パスの記録が重複した")
        #expect(records.first?.localIdentifier == "NEW-ID",
                "記録が消えた旧 ID を指したまま＝共有もオフロードもこの写真に届かない")
    }

    @Test("進捗台帳を消しても、済み状態が現在の ID で記録から復元できる")
    func recordedIdentifiersFollowCurrentAsset() async {
        let store = await reimported()
        let ids = await store.recordedLocalIdentifiers()
        #expect(ids.contains("NEW-ID"), "台帳クリア後の済み判定が現在の ID で復元できない")
    }

    @Test("現在の localIdentifier から共有用の Dropbox パスを解決できる")
    func sharePathResolvesFromCurrentIdentifier() async {
        let store = await reimported()
        let refs = await store.backupRefs(forLocalIdentifiers: ["NEW-ID"])
        #expect(refs["NEW-ID"]?.dropboxPath == "/b/img_0001.heic",
                "共有が「バックアップ待ち」から進めない")
        #expect(await store.localToCloudPaths()["NEW-ID"] == "/b/img_0001.heic")
    }

    @Test("オフロード候補の走査（記録 ID → PHAsset）も現在の資産に当たる")
    func offloadIndexPointsAtCurrentAsset() async {
        let store = await reimported()
        let index = await store.backupCopyIndex()
        #expect(index["/b/img_0001.heic"] == "NEW-ID",
                "オフロード候補・二重表示判定が現在の資産を解決できない")
    }
}

// MARK: - アカウント・保存先ごとの分離（レビュー指摘）

/// ⚠️ 再送キューが全アカウント・全保存先で共通だと、切り替えたときに
/// **前の保存先向けのメタデータ（人物名・位置・アルバム）を現在の保存先へ送る**。
@Suite("PendingMetadataStore namespacing")
struct PendingMetadataNamespaceTests {

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], localIdentifier: "id")
    }

    /// ⚠️ アカウント名は**テストごとに一意**にする。キューの実体はプロセス共通の保存領域なので、
    /// 同じ (account, folder) を使うテストが並列に走ると、片方の後始末（`save([:])`）が
    /// もう片方の書き込みを消して**ランダムに落ちる**（CI で 1 度踏んだ）。
    private func account(_ label: String = "acc") -> String { "\(label)-\(UUID().uuidString)" }

    @Test("アカウントが違えばキューは混ざらない")
    func differentAccountsAreIsolated() {
        let folder = "/MosaicPhotos/iPhone-3F2A8C"
        let a = PendingMetadataStore(account: account("acc-a"), folder: folder)
        let b = PendingMetadataStore(account: account("acc-b"), folder: folder)
        defer { _ = a.save([:]); _ = b.save([:]) }

        _ = a.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(b.load().isEmpty, "別アカウントのキューを読んでいる（前の保存先へ送ってしまう）")
        #expect(a.load()["2025-08"]?.count == 1)
    }

    @Test("保存先が違えばキューは混ざらない")
    func differentFoldersAreIsolated() {
        let shared = account()
        let a = PendingMetadataStore(account: shared, folder: "/MosaicPhotos/iPhone-3F2A8C")
        let b = PendingMetadataStore(account: shared, folder: "/Backup2/iPhone-3F2A8C")
        defer { _ = a.save([:]); _ = b.save([:]) }

        _ = a.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(b.load().isEmpty, "別の保存先のキューを読んでいる")
    }

    @Test("同じアカウント・同じ保存先なら同じキューを見る")
    func sameNamespaceShares() {
        let folder = "/MosaicPhotos/iPhone-3F2A8C"
        let shared = account()
        let writer = PendingMetadataStore(account: shared, folder: folder)
        let reader = PendingMetadataStore(account: shared, folder: folder)
        defer { _ = writer.save([:]) }

        _ = writer.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(reader.load()["2025-08"]?["/x/a.jpg"]?.people == ["太郎"])
    }
}

// MARK: - アップロード対象が無い回の再送（レビュー指摘）


private final class DrainToken: AccessTokenProvider {
    func freshAccessToken() async throws -> String { "t" }
}

/// runner の通知先。ドレイン経路は写真に触らないので、記録だけの最小実装で足りる。
@MainActor
private final class StubRunnerDelegate: BackupRunnerDelegate {
    var phases: [BackupEngine.Phase] = []
    /// 再送キューはアカウント指紋で名前空間が決まる。テストごとに一意にして混線を避ける。
    var fingerprint: String = "acct"
    func runnerSetPhase(_ phase: BackupEngine.Phase) { phases.append(phase) }
    func runnerLog(_ message: String) {}
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?) async -> Bool { true }
    func runnerRecordedLocalIdentifiers() async -> Set<String> { [] }
    func runnerShareMemberLocalIdentifiers() async -> Set<String> { [] }
    func runnerAccountFingerprint() async -> String? { fingerprint }
}

/// ⚠️ 「上げる写真が無い」で早期 return すると、前回送れなかったメタデータが
/// **新しい写真が増えるまで永久に滞留**する（人物名・位置・アルバムが欠けたまま）。
@Suite("保留メタデータの再送")
@MainActor
struct PendingMetadataDrainTests {

    private func makeRunner(_ delegate: StubRunnerDelegate,
                            _ server: FakeDropboxServer) -> BackupRunner {
        BackupRunner(tokenProvider: DrainToken(),
                     uploader: DropboxBackupUploader(httpClient: server),
                     progressStore: BackupProgressStore(),
                     uploadLimit: { 0 }, delegate: delegate)
    }

    private func queue(_ payload: PendingMetadataStore.Payload) -> PendingMetadataStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PendingMetadataStore(directory: dir, filename: "pending.json")
        _ = store.save(payload)
        return store
    }

    private var payload: PendingMetadataStore.Payload {
        ["2023-11": ["/backup/a.jpg": DropboxBackupMetadata.Entry(people: ["名前"], albums: ["Trip"],
                                                                 localIdentifier: "a")]]
    }

    @Test("新規アップロードが 1 枚も無くても、保留分は送り直してキューが空になる")
    func drainsQueueWithoutNewUploads() async {
        let server = FakeDropboxServer()
        let delegate = StubRunnerDelegate()
        let store = queue(payload)

        await makeRunner(delegate, server).drainPendingMetadata(folder: "/backup", pendingStore: store)

        let uploaded = await server.uploadedPaths
        #expect(uploaded.contains { $0.contains("2023-11") }, "保留分を送っていない: \(uploaded)")
        #expect(store.load().isEmpty, "送れたのにキューに残っている（次回また送る）")
    }

    /// ⚠️ **再送でもカタログにシャードを登録する**（ADR-200）。読む側はカタログに載った
    /// シャードしか開かないので、登録しないと「送り直したのに届かない」が続く——前回書けな
    /// かった月は `written` に入らずカタログにも載らないため、そのまま取り残される。
    /// ただしこのパスは albums/people の索引を作っていないので、**名前は触らない**
    /// （空の索引で上書きすると既存のアルバム名・人物名が消える）。
    @Test("再送はカタログにシャードを足すが、既存の名前は消さない")
    func drainRegistersShardWithoutClearingNames() async {
        let server = FakeDropboxServer()
        let existing = BackupCatalog(shards: ["2023-10"], albums: ["Trip"], people: ["名前"])
        await server.upload(path: "/backup/.mosaic/catalog.json",
                            data: try! JSONEncoder().encode(existing))
        let store = queue(payload)

        await makeRunner(StubRunnerDelegate(), server).drainPendingMetadata(folder: "/backup",
                                                                            pendingStore: store)

        guard let written = await server.body(at: "/backup/.mosaic/catalog.json"),
              let catalog = try? JSONDecoder().decode(BackupCatalog.self, from: written) else {
            Issue.record("カタログを書いていない（再送したシャードが読まれない）")
            return
        }
        #expect(catalog.shards.contains("2023-11"), "送り直したシャードを登録していない")
        #expect(catalog.shards.contains("2023-10"), "既存のシャード一覧を落とした")
        #expect(catalog.albums == ["Trip"], "空の索引でアルバム名を消した")
        #expect(catalog.people == ["名前"], "空の索引で人物名を消した")
    }

    /// ⚠️ **1 回の実行で同じシャードを 2 度送らない**（ADR-200）。
    /// 旧実装は実行の前半（背景経路の先出し＝`drainPendingMetadata`）と後半（`writeMetadata`）の
    /// 両方がキューを読み、前半はジャーナルを消さないので同じ行が 2 回流れていた。
    /// 通信は課金と枠の消費なので、**回数で**確かめる（ADR-119 の考え方）。
    @Test("先出しと本送信が続けて走っても、同じシャードは 1 回しか送らない")
    func theSameShardIsSentOnce() async {
        let server = FakeDropboxServer()
        let store = queue([:])
        // 写真 1 枚ぶんがジャーナルに入った状態（アップロード完了ごとに 1 行足される）。
        #expect(store.appendEntry(
            shard: "2023-11", path: "/backup/a.jpg",
            entry: DropboxBackupMetadata.Entry(people: ["名前"], albums: ["Trip"],
                                               localIdentifier: "a")))
        let runner = makeRunner(StubRunnerDelegate(), server)

        // 実行の前半（背景経路の先出し）→ 後半（本送信）。
        await runner.drainPendingMetadata(folder: "/backup", pendingStore: store)
        await runner.writeMetadata(newEntries: [], indexes: BackupRunner.Indexes(people: [:], albums: [:], albumIDs: [:]),
                                   folder: "/backup", token: "t")

        let shardUploads = await server.uploadedPaths.filter { $0.contains("meta/2023-11") }
        #expect(shardUploads.count == 1,
                "同じシャードを \(shardUploads.count) 回送っている（通信と枠の無駄・二重送信）")
        #expect(store.load().isEmpty, "送れたのにキューに残っている")
    }

    @Test("送れなかった分はキューに残る")
    func failedEntriesStayQueued() async {
        let server = FakeDropboxServer()
        // ⚠️ 403（権限）＝やり直さない失敗。429・5xx は自力で 3 回やり直すのでテストが待たされる。
        await server.failUploads(matching: ".mosaic", status: 403)
        let store = queue(payload)

        await makeRunner(StubRunnerDelegate(), server).drainPendingMetadata(folder: "/backup",
                                                                            pendingStore: store)

        #expect(!store.load().isEmpty, "送信に失敗したのにキューから消えた（欠落が永久化する）")
    }
}

// MARK: - 壊れたカタログ（レビュー指摘）

/// パスごとに download 応答を差し替えられ、アップロード先を記録するクライアント。

/// ⚠️ カタログ（アルバム名・人物名・シャード一覧・アルバム ID 対応）も、
/// 「200 で取れたが読めない」を不在と同じ経路で扱うと**空から作り直して上書き**してしまう。
@Suite("壊れたカタログを空で上書きしない")
@MainActor
struct CatalogDurabilityTests {

    private func entry() -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: ["太郎"], albums: ["旅行"], localIdentifier: "id")
    }

    @Test("既存カタログが読めない JSON なら書かず、書けたシャードを再送キューへ戻す")
    func brokenCatalogIsNotOverwritten() async {
        let folder = "/backup"
        let catalogPath = folder + BackupMetadataV2.catalogSuffix
        let server = FakeDropboxServer()
        // 「200 で取れたが読めない」既存カタログ（HTML が返る等）を置く。
        await server.upload(path: catalogPath, data: Data("<html>not json</html>".utf8))
        let delegate = StubRunnerDelegate()
        delegate.fingerprint = "acct-\(UUID().uuidString)"
        let queue = PendingMetadataStore(account: delegate.fingerprint, folder: folder)
        defer { _ = queue.save([:]) }

        let runner = BackupRunner(tokenProvider: DrainToken(),
                                  uploader: DropboxBackupUploader(httpClient: server),
                                  progressStore: BackupProgressStore(),
                                  uploadLimit: { 0 }, delegate: delegate)
        await runner.writeMetadata(
            newEntries: [BackupMetadataPlanning.NewEntry(
                path: "\(folder)/a.jpg",
                date: Date(timeIntervalSince1970: 1_700_000_000),
                entry: entry())],
            indexes: BackupRunner.Indexes(people: [:], albums: [:], albumIDs: [:]),
            folder: folder, token: "t")

        let uploaded = await server.uploadedPaths
        #expect(!uploaded.contains(catalogPath),
                "読めない既存カタログを空から作り直して上書きした: \(uploaded)")
        #expect(uploaded.contains { $0.contains("meta/") }, "シャードは書けているはず")
        #expect(!queue.load().isEmpty,
                "カタログを書けなかったのにシャードを再送キューへ戻していない（次回作り直せない）")
    }
}

// MARK: - 重複判定用の射影（常駐経路の確保を最小にする）

/// ⚠️ 実機でメモリ 1GB 超のクラッシュを経験している。常駐経路（起動時に必ず通る）の確保は
/// 最小にする。重複判定に要るのは 2 列だけなので、全カラムを materialize しない。
@Suite("バックアップ重複判定の索引")
@MainActor
struct BackupCopyIndexTests {

    private func store() -> BackupStore {
        BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
    }

    @Test("パス（小文字）から localIdentifier を引ける")
    func mapsPathToLocalIdentifier() async {
        let store = store()
        await store.upsertRecord(dropboxPath: "/MosaicPhotos/IMG_1.jpg", localIdentifier: "L-1",
                                 filename: "IMG_1.jpg", creationDate: nil, contentHash: "h1",
                                 people: [], albums: [], isFavorite: false)
        let index = await store.backupCopyIndex()
        #expect(index["/mosaicphotos/img_1.jpg"] == "L-1", "パスの大小で引けないと重複を隠せない")
    }

    /// 対応が分からないものを隠すと、写真が消えたように見える（取り返しがつかない）。
    @Test("localIdentifier が無い記録は入れない")
    func skipsRecordsWithoutLocalIdentifier() async {
        let store = store()
        await store.upsertRecord(dropboxPath: "/MosaicPhotos/IMG_2.jpg", localIdentifier: nil,
                                 filename: "IMG_2.jpg", creationDate: nil, contentHash: "h2",
                                 people: [], albums: [], isFavorite: false)
        #expect(await store.backupCopyIndex().isEmpty)
    }

    @Test("記録が無ければ空")
    func emptyStore() async {
        #expect(await store().backupCopyIndex().isEmpty)
    }

    @Test("全記録ぶん引ける")
    func coversAllRecords() async {
        let store = store()
        for i in 0..<50 {
            await store.upsertRecord(dropboxPath: "/MosaicPhotos/IMG_\(i).jpg",
                                     localIdentifier: "L-\(i)", filename: "IMG_\(i).jpg",
                                     creationDate: nil, contentHash: "h\(i)",
                                     people: [], albums: [], isFavorite: false)
        }
        #expect(await store.backupCopyIndex().count == 50)
    }
}
