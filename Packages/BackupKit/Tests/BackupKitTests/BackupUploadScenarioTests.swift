import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// **バックアップの現実的な失敗**を、状態を持つ偽 Dropbox で通す。
///
/// 見ているのは 3 つ。
///   1. 同名で**別物**の写真が来たとき、実際の保存先（autorename 後の名前）を台帳が持てるか
///      ——持てないと、オフロードの照合が**別のファイル**を見ることになる
///   2. レート制限が続く回に「済み」にしないこと（＝次回もう一度上げ直せる）
///   3. 無駄に上げ直していないこと（`uploadCount()` で数える）
@Suite("バックアップのアップロード（衝突・レート制限）")
struct BackupUploadScenarioTests {

    private let folder = "/MosaicPhotos/iPhone-E7/Backup/2023/2023-11"
    private let photoA = Data("photo-A-bytes".utf8)
    private let photoB = Data("photo-B-different".utf8)

    private func uploader(_ server: FakeDropboxServer) -> DropboxBackupUploader {
        DropboxBackupUploader(httpClient: server)
    }

    // MARK: - 同名衝突（autorename）

    /// ⚠️ 同じ名前で**中身が違う**写真は珍しくない（IMG_0001.JPG は端末を変えると再発する）。
    /// Dropbox は `mode=add` で衝突すると 409 を返し、`autorename=true` なら別名で保存して
    /// **実際の保存先**を返す。台帳がその保存先を持てないと、あとでオフロードするときに
    /// **別の写真と照合**することになる。
    @Test("同名で別物なら 409 → autorename で別名保存され、実際の保存先が返る")
    func conflictingNameIsAutorenamed() async {
        let server = FakeDropboxServer()
        let path = "\(folder)/IMG_0001.jpg"

        let first = await uploader(server).upload(data: photoA, to: path, token: "t",
                                                  expectedHash: DropboxContentHash.hash(of: photoA))
        guard case .uploaded(let firstPath, _) = first else {
            Issue.record("1 枚目が上がっていない: \(first)")
            return
        }
        #expect(firstPath == path.lowercased())

        // 2 枚目は同名・別内容。autorename なしでは 409（既存を壊さない）。
        let conflict = await uploader(server).upload(data: photoB, to: path, token: "t",
                                                     expectedHash: DropboxContentHash.hash(of: photoB))
        #expect(conflict == .alreadyExists, "同名の別物を黙って上書きした（1 枚目が失われる）")

        // 呼び出し側は同一性を確かめたうえで autorename=true で再試行する。
        let renamed = await uploader(server).upload(data: photoB, to: path, token: "t",
                                                    expectedHash: DropboxContentHash.hash(of: photoB),
                                                    autorename: true)
        guard case .uploaded(let savedPath, _) = renamed else {
            Issue.record("autorename で上がっていない: \(renamed)")
            return
        }
        #expect(savedPath != path.lowercased(), "別名になっていない（上書きされている）")
        #expect(await server.filePaths().count == 2, "2 枚とも残っていない")
    }

    /// ⚠️ **写真が消える経路**: 台帳が要求したパス（別名になる前）を持っていると、
    /// オフロードの照合は**別の写真**を見る。hash が違うので見送られる——つまり
    /// 「消さない」側に倒れるのが正しい。実際の保存先を持っていれば正しく消せる。
    @Test("台帳が実際の保存先を持っていないと、オフロードは見送られる（誤って消さない）")
    func offloadVerifiesAgainstTheSavedPath() async {
        let server = FakeDropboxServer()
        let requested = "\(folder)/IMG_0001.jpg"
        _ = await uploader(server).upload(data: photoA, to: requested, token: "t",
                                          expectedHash: DropboxContentHash.hash(of: photoA))
        let renamed = await uploader(server).upload(data: photoB, to: requested, token: "t",
                                                    expectedHash: DropboxContentHash.hash(of: photoB),
                                                    autorename: true)
        guard case .uploaded(let savedPath, _) = renamed else {
            Issue.record("前提が作れていない: \(renamed)")
            return
        }

        func offload(recordedPath: String) async -> (deleted: [String], skipped: [(String, String)]) {
            let service = await OffloadService(
                uploader: uploader(server), tokenProvider: FakeTokenProvider(),
                deleter: AlwaysDeletes(), backupRoot: "/MosaicPhotos/iPhone-E7/Backup",
                log: { _ in })
            let asset = OffloadableAsset(
                localIdentifier: "ID-b", dropboxPath: recordedPath, filename: "IMG_0001.jpg",
                albums: [], captureDate: Date(timeIntervalSince1970: 1_700_000_000),
                modificationDate: nil, backedUpAt: Date(), isLivePhoto: false,
                loadData: { [photoB] in (photoB, false) })
            return await service.execute(assets: [asset], limit: 10,
                                         recordLedger: { _ in true }, rollbackLedger: { _ in })
        }

        // 取り違えた記録（要求したパス）では、別物と照合されるので消さない。
        let wrong = await offload(recordedPath: requested)
        #expect(wrong.deleted.isEmpty, "別の写真と照合したのに削除した（写真が失われる）")

        // 実際の保存先を持っていれば、正しく照合して消せる。
        let right = await offload(recordedPath: savedPath)
        #expect(right.deleted == ["ID-b"], "正しい保存先なのに消せていない: \(right.skipped)")
    }

    // MARK: - レート制限

    /// ⚠️ 上がっていないのに「済み」にすると、その写真は二度と対象にならない＝
    /// バックアップに穴が空いたまま、オフロードの候補にもなり得る。
    @Test("レート制限が続く回は「済み」にしない（次回やり直せる）")
    func persistentRateLimitIsNotTreatedAsDone() async {
        let server = FakeDropboxServer()
        let path = "\(folder)/a.jpg"
        await server.failUploads(matching: "a.jpg", status: 429)

        let result = await uploader(server).upload(data: photoA, to: path, token: "t",
                                                   expectedHash: DropboxContentHash.hash(of: photoA))

        if case .uploaded = result { Issue.record("上がっていないのに済み扱いにした") }
        #expect(await server.filePaths().isEmpty, "サーバーに残っているのはおかしい")
    }

    /// **やり直しの分担**（意図的に非対称）。
    /// - **写真の本体**: 429 でその場では**やり直さない**。済み扱いにしないので次回の実行で
    ///   もう一度対象になる。1 枚あたり数 MB の再送をその場で繰り返すより、枠を譲る方がよい。
    /// - **メタデータ（シャード・カタログ）**: その場で最大 3 回やり直す（2 秒 → 4 秒）。
    ///   写真は既に上がっていて完了記録が付くため、ここで諦めると人物名・アルバム・位置情報が
    ///   再送キューに滞留する（実機 diagnostics-74）。
    ///
    /// ⚠️ この非対称は読み取りにくいので、テストで固定して意図を残す。
    @Test("やり直しの分担: 写真は次回に回し、メタデータはその場でやり直す")
    func retryPolicyDiffersBetweenPhotosAndMetadata() async {
        // (1) 写真: 1 回だけ 429 → その場では諦める（次回の実行に回る）。
        let photoServer = FakeDropboxServer()
        await photoServer.failUploads(matching: "a.jpg", status: 429, times: 1)
        let photoResult = await uploader(photoServer).upload(
            data: photoA, to: "\(folder)/a.jpg", token: "t",
            expectedHash: DropboxContentHash.hash(of: photoA))
        if case .uploaded = photoResult {
            Issue.record("写真の本体をその場でやり直している（枠を食う設計に変わった？）")
        }
        #expect(await photoServer.filePaths().isEmpty)

        // (2) メタデータ: 1 回だけ 429 → その場でやり直して通す。
        let metaServer = FakeDropboxServer()
        await metaServer.failUploads(matching: "catalog.json", status: 429, times: 1)
        let metaResult = await uploader(metaServer).uploadJSONResult(
            BackupCatalog(shards: ["2023-11"]),
            to: "/MosaicPhotos/iPhone-E7/Backup/.mosaic/catalog.json", token: "t")
        #expect(metaResult.ok,
                "メタデータをその場でやり直していない（再送キューが枠をまたいで滞留する）")
    }

    /// 同じ写真をもう一度上げても、**増えない**（同じパス・同じ内容＝上書き相当）。
    /// 中断して再実行したときに、ファイルが二重にならないことの確認。
    @Test("同じ写真を上げ直してもファイルは増えない")
    func reuploadingTheSamePhotoDoesNotDuplicate() async {
        let server = FakeDropboxServer()
        let path = "\(folder)/a.jpg"
        let hash = DropboxContentHash.hash(of: photoA)

        _ = await uploader(server).upload(data: photoA, to: path, token: "t", expectedHash: hash)
        _ = await uploader(server).upload(data: photoA, to: path, token: "t", expectedHash: hash)

        let paths = await server.filePaths()
        #expect(paths == [path.lowercased()], "同じ写真が 2 つに増えた: \(paths)")
    }
}

/// 削除要求を必ず受け入れる（このファイルは「消してよい条件」ではなく照合先を見ている）。
private final class AlwaysDeletes: PhotoDeleter, @unchecked Sendable {
    func delete(localIdentifiers: [String]) async -> Bool { true }
}
