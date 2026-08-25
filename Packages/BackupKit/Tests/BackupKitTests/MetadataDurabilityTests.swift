import DropboxCore
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
    private actor Fake: HTTPClient {
        /// download の応答（path → (status, body)）。既定は 200 + 空シャード。
        var downloadResponses: [String: (Int, String)] = [:]
        var uploadStatus = 200
        private(set) var uploadedBodies: [String: String] = [:]

        init(downloadResponses: [String: (Int, String)] = [:], uploadStatus: Int = 200) {
            self.downloadResponses = downloadResponses
            self.uploadStatus = uploadStatus
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!.absoluteString
            func resp(_ code: Int, _ body: String) -> (Data, URLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            struct Arg: Decodable { let path: String }
            let arg = request.value(forHTTPHeaderField: "Dropbox-API-Arg")
                .flatMap { try? JSONDecoder().decode(Arg.self, from: Data($0.utf8)) }
            let path = arg?.path ?? ""

            if url.contains("files/download") {
                let (code, body) = downloadResponses[path] ?? (200, #"{"entries":{}}"#)
                return resp(code, body)
            }
            if url.contains("files/upload") {
                uploadedBodies[path] = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return resp(uploadStatus, "{}")
            }
            return resp(200, "{}")
        }

        func uploaded(_ path: String) -> String? { uploadedBodies[path] }
        func uploadCount() -> Int { uploadedBodies.count }
    }

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], localIdentifier: "id")
    }

    // MARK: - 取得失敗を「空」と読まない

    @Test("既存シャードの取得に失敗したら、そのシャードは書かない")
    func failedDownloadSkipsWrite() async {
        // 認証切れ（401）。「無い」ではないので、既存を空で上書きしてはいけない。
        let server = Fake(downloadResponses: ["/b/.mosaic/meta/2025-08.json": (401, "expired_access_token")])
        let writer = MetadataShardWriter(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t")

        let result = await writer.applyEntries(
            byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], folder: "/b") { _ in }

        #expect(await server.uploadCount() == 0, "取得できていないのに上書きした（既存が消える）")
        #expect(result.written.isEmpty)
        #expect(result.failed["2025-08"] != nil, "再送のために失敗分を返していない")
    }

    @Test("ファイルが無い（not_found）ときは新規シャードとして書く")
    func notFoundCreatesNewShard() async {
        let server = Fake(downloadResponses: [
            "/b/.mosaic/meta/2025-08.json": (409, #"{"error_summary":"path/not_found/."}"#)])
        let writer = MetadataShardWriter(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t")

        let result = await writer.applyEntries(
            byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], folder: "/b") { _ in }

        #expect(result.written == ["2025-08"], "新規作成できていない")
        #expect(await server.uploaded("/b/.mosaic/meta/2025-08.json")?.contains("太郎") == true)
    }

    @Test("送信に失敗したシャードは失敗として返る（再送の材料）")
    func failedUploadIsReported() async {
        let server = Fake(uploadStatus: 500)
        let writer = MetadataShardWriter(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t")

        let result = await writer.applyEntries(
            byShard: ["2025-08": ["/b/a.jpg": entry(["太郎"])]], folder: "/b") { _ in }

        #expect(result.written.isEmpty)
        #expect(result.failed["2025-08"]?.count == 1)
    }

    @Test("送信に失敗した部分更新（マーカー）は false を返す（送信済みにしない）")
    func failedMarkerUpdateIsReported() async {
        let server = Fake(uploadStatus: 500)
        let writer = MetadataShardWriter(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t")

        let ok = await writer.updateEntries(
            paths: ["/b/a.jpg"], folder: "/b", shardName: "2025-08",
            mutate: { $0.offloadedAt = "2026-08-26T00:00:00Z" },
            makeDefault: { _ in DropboxBackupMetadata.Entry(people: [], albums: [],
                                                            localIdentifier: "off-1") },
            log: { _ in })

        #expect(!ok, "書けていないのに成功を返すと、台帳に送信済みの印が付いて再送されない")
    }

    // MARK: - 並行するシャード更新（レビュー指摘）

    /// **状態を持つ**偽 Dropbox。アップロードされた JSON を保持し、以後の download がそれを返す。
    /// download に人工的な遅延を入れ、read-modify-write の競合を確実に作る。
    private actor StatefulShardServer: HTTPClient {
        private var stored: [String: String] = [:]
        private let uploadStatus: Int
        private let downloadDelayNs: UInt64

        init(uploadStatus: Int = 200, downloadDelayNs: UInt64 = 30_000_000) {
            self.uploadStatus = uploadStatus
            self.downloadDelayNs = downloadDelayNs
        }

        func body(at path: String) -> String? { stored[path] }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = request.url!.absoluteString
            func resp(_ code: Int, _ body: String) -> (Data, URLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                                  httpVersion: nil, headerFields: nil)!)
            }
            struct Arg: Decodable { let path: String }
            let path = request.value(forHTTPHeaderField: "Dropbox-API-Arg")
                .flatMap { try? JSONDecoder().decode(Arg.self, from: Data($0.utf8)) }?.path ?? ""

            if url.contains("files/download") {
                // 遅い download（actor の再入で、直列化されていなければ両者が同じ旧内容を読む）。
                try? await Task.sleep(nanoseconds: downloadDelayNs)
                guard let body = stored[path] else {
                    return resp(409, #"{"error_summary":"path/not_found/."}"#)
                }
                return resp(200, body)
            }
            if url.contains("files/upload") {
                guard uploadStatus == 200 else { return resp(uploadStatus, "{}") }
                stored[path] = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                return resp(200, "{}")
            }
            return resp(200, "{}")
        }
    }

    @Test("同じシャードへのバックアップ追記とオフロードマーカー更新が並行しても、両方が残る")
    func concurrentShardUpdatesKeepBothChanges() async {
        // ⚠️ 直列化していないと、後着の overwrite が先着の変更を消す。消えたのがマーカーだと
        // 台帳は「送信済み」なので再送されず、再インストール後に台帳を再構築できない。
        let folder = "/concurrent"
        let shardPath = folder + BackupMetadataV2.shardSuffix("2025-08")
        let server = StatefulShardServer()
        let writer = MetadataShardWriter(uploader: DropboxBackupUploader(httpClient: server),
                                         token: "t")

        async let backup = writer.applyEntries(
            byShard: ["2025-08": ["\(folder)/new.jpg": entry(["太郎"])]], folder: folder) { _ in }
        async let marker = writer.updateEntries(
            paths: ["\(folder)/offloaded.jpg"], folder: folder, shardName: "2025-08",
            mutate: { $0.offloadedAt = "2026-08-26T00:00:00Z" },
            makeDefault: { _ in DropboxBackupMetadata.Entry(people: [], albums: [],
                                                            localIdentifier: "off-1") },
            log: { _ in })
        let applied = await backup
        let markerOK = await marker

        #expect(applied.written == ["2025-08"])
        #expect(markerOK)
        let final = await server.body(at: shardPath) ?? ""
        let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: Data(final.utf8))
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
}

// MARK: - アカウント・保存先ごとの分離（レビュー指摘）

/// ⚠️ 再送キューが全アカウント・全保存先で共通だと、切り替えたときに
/// **前の保存先向けのメタデータ（人物名・位置・アルバム）を現在の保存先へ送る**。
@Suite("PendingMetadataStore namespacing")
struct PendingMetadataNamespaceTests {

    private func entry(_ people: [String]) -> DropboxBackupMetadata.Entry {
        DropboxBackupMetadata.Entry(people: people, albums: [], localIdentifier: "id")
    }

    @Test("アカウントが違えばキューは混ざらない")
    func differentAccountsAreIsolated() {
        let folder = "/MosaicPhotos/iPhone-3F2A8C"
        let a = PendingMetadataStore(account: "acc-a", folder: folder)
        let b = PendingMetadataStore(account: "acc-b", folder: folder)
        defer { _ = a.save([:]); _ = b.save([:]) }

        _ = a.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(b.load().isEmpty, "別アカウントのキューを読んでいる（前の保存先へ送ってしまう）")
        #expect(a.load()["2025-08"]?.count == 1)
    }

    @Test("保存先が違えばキューは混ざらない")
    func differentFoldersAreIsolated() {
        let a = PendingMetadataStore(account: "acc", folder: "/MosaicPhotos/iPhone-3F2A8C")
        let b = PendingMetadataStore(account: "acc", folder: "/Backup2/iPhone-3F2A8C")
        defer { _ = a.save([:]); _ = b.save([:]) }

        _ = a.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(b.load().isEmpty, "別の保存先のキューを読んでいる")
    }

    @Test("同じアカウント・同じ保存先なら同じキューを見る")
    func sameNamespaceShares() {
        let folder = "/MosaicPhotos/iPhone-3F2A8C"
        let writer = PendingMetadataStore(account: "acc", folder: folder)
        let reader = PendingMetadataStore(account: "acc", folder: folder)
        defer { _ = writer.save([:]) }

        _ = writer.save(["2025-08": ["/x/a.jpg": entry(["太郎"])]])
        #expect(reader.load()["2025-08"]?["/x/a.jpg"]?.people == ["太郎"])
    }
}

// MARK: - アップロード対象が無い回の再送（レビュー指摘）

/// アップロード先パス・本文を記録するだけのクライアント（シャードは常に「新規」）。
private actor MarkerRecorder: HTTPClient {
    private(set) var uploaded: [String] = []
    var failUploads = false
    func setFailUploads(_ value: Bool) { failUploads = value }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        func resp(_ code: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: nil)!)
        }
        if url.contains("download") || url.contains("get_metadata") {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        if url.contains("upload") {
            struct Arg: Decodable { let path: String }
            let raw = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "{}"
            uploaded.append((try? JSONDecoder().decode(Arg.self, from: Data(raw.utf8)))?.path ?? "?")
            return failUploads ? resp(500, "{}") : resp(200, "{}")
        }
        return resp(200, "{}")
    }
}

private final class DrainToken: AccessTokenProvider {
    func freshAccessToken() async throws -> String { "t" }
}

/// runner の通知先。ドレイン経路は写真に触らないので、記録だけの最小実装で足りる。
@MainActor
private final class StubRunnerDelegate: BackupRunnerDelegate {
    var phases: [BackupEngine.Phase] = []
    func runnerSetPhase(_ phase: BackupEngine.Phase) { phases.append(phase) }
    func runnerLog(_ message: String) {}
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?) async -> Bool { true }
    func runnerRecordedLocalIdentifiers() async -> Set<String> { [] }
    func runnerPriorityLocalIdentifiers() async -> Set<String> { [] }
    func runnerAccountFingerprint() async -> String? { "acct" }
}

/// ⚠️ 「上げる写真が無い」で早期 return すると、前回送れなかったメタデータが
/// **新しい写真が増えるまで永久に滞留**する（人物名・位置・アルバムが欠けたまま）。
@Suite("保留メタデータの再送")
@MainActor
struct PendingMetadataDrainTests {

    private func makeRunner(_ delegate: StubRunnerDelegate,
                            _ server: MarkerRecorder) -> BackupRunner {
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
        let server = MarkerRecorder()
        let delegate = StubRunnerDelegate()
        let store = queue(payload)

        await makeRunner(delegate, server).drainPendingMetadata(folder: "/backup", pendingStore: store)

        let uploaded = await server.uploaded
        #expect(uploaded.contains { $0.contains("2023-11") }, "保留分を送っていない: \(uploaded)")
        #expect(store.load().isEmpty, "送れたのにキューに残っている（次回また送る）")
    }

    /// このパスは albums/people の索引を作っていない。カタログを書くと**既存の名前が消える**。
    @Test("再送ではカタログを書かない")
    func drainDoesNotTouchCatalog() async {
        let server = MarkerRecorder()
        let store = queue(payload)

        await makeRunner(StubRunnerDelegate(), server).drainPendingMetadata(folder: "/backup",
                                                                            pendingStore: store)

        let uploaded = await server.uploaded
        #expect(!uploaded.contains { $0.hasSuffix("catalog.json") },
                "空の索引でカタログを上書きした: \(uploaded)")
    }

    @Test("送れなかった分はキューに残る")
    func failedEntriesStayQueued() async {
        let server = MarkerRecorder()
        await server.setFailUploads(true)
        let store = queue(payload)

        await makeRunner(StubRunnerDelegate(), server).drainPendingMetadata(folder: "/backup",
                                                                            pendingStore: store)

        #expect(!store.load().isEmpty, "送信に失敗したのにキューから消えた（欠落が永久化する）")
    }
}
