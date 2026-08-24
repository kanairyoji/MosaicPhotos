import DropboxCore
import Foundation
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
