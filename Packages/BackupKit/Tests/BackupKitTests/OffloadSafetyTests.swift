import DropboxCore
import Foundation
import Testing
@testable import BackupKit

// MARK: - テストダブル（層 2: 偽 Dropbox ＋ 削除呼び出しの記録）

/// パスごとに応答を返す偽 Dropbox。get_metadata / download / upload を最低限エミュレート。
private actor FakeDropbox: HTTPClient {
    /// path → (content_hash, size)。無いパスへの get_metadata は 409。
    var files: [String: (hash: String, size: Int)]
    init(files: [String: (hash: String, size: Int)]) { self.files = files }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        func resp(_ code: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: nil)!)
        }
        if url.contains("get_metadata") {
            struct Body: Decodable { let path: String }
            guard let body = request.httpBody,
                  let parsed = try? JSONDecoder().decode(Body.self, from: body),
                  let file = files[parsed.path] else {
                return resp(409, #"{"error_summary":"path/not_found/"}"#)
            }
            return resp(200, #"{"content_hash":"\#(file.hash)","size":\#(file.size)}"#)
        }
        if url.contains("download") {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)   // シャード無し＝新規
        }
        if url.contains("upload") {
            // マーカー書き込み。失敗を注入できるようにする（再送の検証に使う）。
            return failMarkerUpload ? resp(500, "{}") : resp(200, "{}")
        }
        return resp(200, "{}")
    }

    /// metadata シャードのアップロードを失敗させる。
    var failMarkerUpload = false
    func setFailMarkerUpload(_ value: Bool) { failMarkerUpload = value }
}

/// 削除要求を記録するだけのモック（実削除しない）。
private final class MockDeleter: PhotoDeleter, @unchecked Sendable {
    private(set) var deletedIDs: [[String]] = []
    var result = true   // false = ユーザーがダイアログでキャンセル
    func delete(localIdentifiers: [String]) async -> Bool {
        deletedIDs.append(localIdentifiers)
        return result
    }
}

private final class StubToken: AccessTokenProvider {
    func freshAccessToken() async throws -> String { "test-token" }
}

// MARK: - Tests

/// オフロード安全性（ADR-40・層 2）: 「削除は証明の後」の不変条件を、
/// すべての失敗パスについて**削除要求が出ないこと**で保証する。
@Suite("Offload safety (deletion requires proof)")
@MainActor
struct OffloadSafetyTests {

    private let photoData = Data("photo-bytes".utf8)
    private var photoHash: String { DropboxContentHash.hash(of: photoData) }

    private func asset(id: String = "ID-1", path: String = "/backup/img_0001.jpg",
                       modified: Date? = nil, backedUpAt: Date? = Date(),
                       live: Bool = false, data: Data?) -> OffloadableAsset {
        OffloadableAsset(localIdentifier: id, dropboxPath: path, filename: "img_0001.jpg",
                         albums: ["旅行"], captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                         modificationDate: modified, backedUpAt: backedUpAt,
                         isLivePhoto: live, loadData: { data })
    }

    private func makeService(files: [String: (hash: String, size: Int)],
                             deleter: MockDeleter) -> OffloadService {
        OffloadService(uploader: DropboxBackupUploader(httpClient: FakeDropbox(files: files)),
                       tokenProvider: StubToken(), deleter: deleter, log: { _ in })
    }

    // MARK: 正常系

    @Test("hash・サイズが完全一致する写真だけが削除される（台帳記録つき）")
    func happyPath() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        var ledger: [String] = []
        let result = await service.execute(
            assets: [asset(data: photoData)], limit: 10,
            recordLedger: { items in ledger = items.map(\.localIdentifier); return true },
            rollbackLedger: { _ in Issue.record("rollback should not happen") })
        #expect(result.deleted == ["ID-1"])
        #expect(deleter.deletedIDs == [["ID-1"]])
        #expect(ledger == ["ID-1"])   // 記録が削除より先（recordLedger が呼ばれている）
    }

    // MARK: 失敗パス＝削除要求ゼロ件を保証

    @Test("クラウドに実在しない → 削除しない")
    func notOnCloud() async {
        let deleter = MockDeleter()
        let service = makeService(files: [:], deleter: deleter)   // Dropbox は空
        let result = await service.execute(assets: [asset(data: photoData)], limit: 10,
                                           recordLedger: { _ in Issue.record("must not record"); return true },
                                           rollbackLedger: { _ in })
        #expect(result.deleted.isEmpty)
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("not found") == true)
    }

    @Test("hash 不一致（クラウドのファイルが別物）→ 削除しない")
    func hashMismatch() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: "different-hash", size: photoData.count)],
            deleter: deleter)
        let result = await service.execute(assets: [asset(data: photoData)], limit: 10,
                                           recordLedger: { _ in Issue.record("must not record"); return true },
                                           rollbackLedger: { _ in })
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("hash mismatch") == true)
    }

    @Test("サイズ不一致 → 削除しない")
    func sizeMismatch() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count + 999)],
            deleter: deleter)
        let result = await service.execute(assets: [asset(data: photoData)], limit: 10,
                                           recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("size mismatch") == true)
    }

    @Test("端末データが読めない（iCloud のみ等）→ 削除しない")
    func unreadableData() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        let result = await service.execute(assets: [asset(data: nil)], limit: 10,
                                           recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("could not read") == true)
    }

    @Test("バックアップ後に編集された → 削除しない")
    func editedAfterBackup() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        let backedUp = Date(timeIntervalSince1970: 1_700_000_000)
        let edited = backedUp.addingTimeInterval(3600)
        let result = await service.execute(
            assets: [asset(modified: edited, backedUpAt: backedUp, data: photoData)], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("edited") == true)
    }

    @Test("Live Photo → 削除しない（動画部分が未バックアップ）")
    func livePhoto() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        let result = await service.execute(assets: [asset(live: true, data: photoData)], limit: 10,
                                           recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(deleter.deletedIDs.isEmpty)
        #expect(result.skipped.first?.1.contains("Live Photo") == true)
    }

    @Test("ユーザーが削除ダイアログをキャンセル → 台帳がロールバックされる")
    func userCancelRollsBackLedger() async {
        let deleter = MockDeleter()
        deleter.result = false   // キャンセル
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        var recorded: [String] = []
        var rolledBack: [String] = []
        let result = await service.execute(
            assets: [asset(data: photoData)], limit: 10,
            recordLedger: { items in recorded = items.map(\.localIdentifier); return true },
            rollbackLedger: { ids in rolledBack = ids })
        #expect(result.deleted.isEmpty)
        #expect(recorded == ["ID-1"])     // 記録は先に行われ…
        #expect(rolledBack == ["ID-1"])   // …キャンセルで確実に取り消される
    }

    @Test("上限（limit）を超える分は削除しない")
    func limitCap() async {
        let deleter = MockDeleter()
        let files = (1...5).reduce(into: [String: (hash: String, size: Int)]()) { dict, i in
            dict["/backup/img_000\(i).jpg"] = (hash: photoHash, size: photoData.count)
        }
        let service = makeService(files: files, deleter: deleter)
        let assets = (1...5).map {
            asset(id: "ID-\($0)", path: "/backup/img_000\($0).jpg", data: photoData)
        }
        let result = await service.execute(assets: assets, limit: 2,
                                           recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(result.deleted.count == 2)
        #expect(deleter.deletedIDs.flatMap(\.self).count == 2)
    }

    @Test("plan（ドライラン）は削除要求を一切出さない")
    func planNeverDeletes() async {
        let deleter = MockDeleter()
        let service = makeService(
            files: ["/backup/img_0001.jpg": (hash: photoHash, size: photoData.count)],
            deleter: deleter)
        let plan = await service.plan(assets: [asset(data: photoData)], limit: 10)
        #expect(plan.eligible.count == 1)
        #expect(deleter.deletedIDs.isEmpty)   // eligible でも削除は起きない
    }
}

// MARK: - 台帳の永続化失敗・マーカー再送（レビュー指摘）

/// ⚠️ 「記録が先」は**記録できたこと**まで確認して初めて成り立つ。
/// 保存失敗（容量不足・SwiftData 障害）を握り潰して消すと、クラウドにしか無い写真が
/// 台帳から漏れて追跡不能になる。
@Suite("Offload ledger durability")
@MainActor
struct OffloadLedgerDurabilityTests {

    private let photoData = Data("photo-bytes".utf8)

    private func asset(_ id: String) -> OffloadableAsset {
        let data = photoData
        return OffloadableAsset(
            localIdentifier: id, dropboxPath: "/backup/\(id).jpg", filename: "\(id).jpg",
            albums: ["Trip"], captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: nil, backedUpAt: Date(timeIntervalSince1970: 1_700_000_100),
            isLivePhoto: false, loadData: { data })
    }

    @Test("台帳の保存に失敗したら削除しない")
    func ledgerWriteFailureAbortsDeletion() async {
        let hash = DropboxContentHash.hash(of: photoData)
        let server = FakeDropbox(files: ["/backup/a.jpg": (hash, photoData.count)])
        let deleter = MockDeleter()
        let service = OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                                     tokenProvider: StubToken(), deleter: deleter, log: { _ in })
        var rolledBack: [String] = []

        let result = await service.execute(
            assets: [asset("a")], limit: 10,
            recordLedger: { _ in false },                 // 保存できなかった
            rollbackLedger: { ids in rolledBack = ids })

        #expect(deleter.deletedIDs.isEmpty, "台帳に記録できていないのに写真を消した")
        #expect(result.deleted.isEmpty)
        #expect(rolledBack == ["a"], "書けたかもしれない分を戻していない")
        #expect(result.skipped.contains { $0.1.contains("ledger") }, "理由が伝わらない")
    }

    /// ⚠️ マーカーを書けなかった写真は**もう端末に無い**ので、候補走査（PHAsset）には
    /// 現れない＝次回のオフロード実行では再試行されない。台帳を出典に再送すること。
    @Test("マーカー送信に失敗しても、台帳から再送できる")
    func pendingMarkersAreRetriedFromLedger() async {
        let hash = DropboxContentHash.hash(of: photoData)
        let server = FakeDropbox(files: ["/backup/a.jpg": (hash, photoData.count)])
        await server.setFailMarkerUpload(true)
        let deleter = MockDeleter()
        let service = OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                                     tokenProvider: StubToken(), deleter: deleter, log: { _ in })
        var markedUploaded: [String] = []

        let result = await service.execute(
            assets: [asset("a")], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in },
            markMarkersUploaded: { ids in markedUploaded = ids })

        // 削除は済んでいる（台帳は書けている）が、マーカーは未送信のまま。
        #expect(result.deleted == ["a"])
        #expect(markedUploaded.isEmpty, "書けていないのに送信済みとして印を付けた")

        // 通信が回復したら、台帳の情報だけで再送できる（写真はもう端末に無い）。
        await server.setFailMarkerUpload(false)
        let target = OffloadMarkerTarget(localIdentifier: "a", dropboxPath: "/backup/a.jpg",
                                         albums: ["Trip"], captureDate: nil)
        let written = await service.uploadOffloadMarkers(for: [target], token: "t")
        #expect(written == ["a"], "再送できていない（再インストール後に復元不能になる）")
    }

    @Test("マーカーを書けた分だけ送信済みとして記録する")
    func successfulMarkersAreRecorded() async {
        let hash = DropboxContentHash.hash(of: photoData)
        let server = FakeDropbox(files: ["/backup/a.jpg": (hash, photoData.count)])
        let service = OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                                     tokenProvider: StubToken(), deleter: MockDeleter(), log: { _ in })
        var markedUploaded: [String] = []
        _ = await service.execute(assets: [asset("a")], limit: 10,
                                  recordLedger: { _ in true }, rollbackLedger: { _ in },
                                  markMarkersUploaded: { ids in markedUploaded = ids })
        #expect(markedUploaded == ["a"])
    }
}
