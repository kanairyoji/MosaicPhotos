import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// **オフロードは失敗しても写真を失わない**——その不変条件を、状態を持つ偽 Dropbox で
/// 通しで確かめる（ADR-40 / ADR-200）。
///
/// ## なぜ「失敗のあと」を試すのか
/// オフロードの怖さは 2 段ある。
///   1. **消してはいけないものを消す**（クラウドに正しいコピーが無いのに削除する）
///   2. **消したあとに印を残せない**（クラウドにはあるのに、復元の手掛かりが無い）
/// 1 は `OffloadSafetyTests` が「削除要求が出ないこと」で守っている。
/// こちらが見るのは **2** ——レート制限・権限・一時障害で印が書けなかったあと、
/// **再送で最終的に届くか**。恒久的な失敗しか作れない偽物では、この収束を確かめられない。
///
/// 検証は必ず**読む側の手順**（`catalog.json` → 載っているシャードだけを開く）で行う。
@Suite("オフロードの回復力（失敗しても写真を失わない）")
@MainActor
struct OffloadResilienceTests {

    private let root = "/MosaicPhotos/iPhone-E7/Backup"
    private let photoData = Data("photo-bytes".utf8)

    private func photoPath(_ name: String, date: Date) -> String {
        let shard = BackupMetadataV2.shardName(for: date)
        return "\(root)/\(shard.prefix(4))/\(shard)/\(name)"
    }

    private let november = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11
    private let may = Date(timeIntervalSince1970: 1_400_000_000)        // 2014-05

    private func target(_ id: String, _ name: String, _ date: Date) -> OffloadMarkerTarget {
        OffloadMarkerTarget(localIdentifier: id, dropboxPath: photoPath(name, date: date),
                            albums: ["旅行"], captureDate: date)
    }

    private func asset(_ id: String, _ name: String, _ date: Date) -> OffloadableAsset {
        OffloadableAsset(localIdentifier: id, dropboxPath: photoPath(name, date: date),
                         filename: name, albums: ["旅行"], captureDate: date,
                         modificationDate: nil, backedUpAt: Date(), isLivePhoto: false,
                         loadData: { [photoData] in (photoData, false) })
    }

    private final class AcceptingDeleter: PhotoDeleter, @unchecked Sendable {
        private(set) var deleted: [String] = []
        func delete(localIdentifiers: [String]) async -> Bool {
            deleted.append(contentsOf: localIdentifiers)
            return true
        }
    }

    private func service(_ server: FakeDropboxServer, deleter: PhotoDeleter) -> OffloadService {
        OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                       tokenProvider: FakeTokenProvider(), deleter: deleter,
                       backupRoot: root, log: { _ in })
    }

    /// 読む側と同じ手順で印を拾う（カタログに載っていないシャードは開かない）。
    private func restorableIDs(_ server: FakeDropboxServer) async -> Set<String> {
        let uploader = DropboxBackupUploader(httpClient: server)
        guard let data = await uploader.download(path: root + BackupMetadataV2.catalogSuffix,
                                                 token: "t"),
              let catalog = try? JSONDecoder().decode(BackupCatalog.self, from: data)
        else { return [] }
        var entries: [String: DropboxBackupMetadata.Entry] = [:]
        for shard in catalog.shards {
            guard let d = await uploader.download(path: root + BackupMetadataV2.shardSuffix(shard),
                                                  token: "t"),
                  let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: d)
            else { continue }
            entries.merge(decoded.entries) { _, new in new }
        }
        return Set(BackupMetadataPlanning.offloadCandidates(from: entries).map(\.localIdentifier))
    }

    // MARK: - 消してはいけないものを消さない（照合が取れない回）

    /// ⚠️ **照合が取れない回に消すと、その写真は失われる。**
    /// レート制限（429）は「ファイルが無い」ではないので、`get_metadata` が返らなかった回を
    /// 「一致した」と読んではいけない。
    @Test("レート制限で照合できない回は、写真を消さない")
    func rateLimitedVerificationNeverDeletes() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.failGetMetadata(matching: "a.jpg", status: 429)
        let deleter = AcceptingDeleter()

        let result = await service(server, deleter: deleter).execute(
            assets: [asset("ID-a", "a.jpg", november)], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in })

        #expect(deleter.deleted.isEmpty, "照合できていないのに削除した（写真が失われる）")
        #expect(result.deleted.isEmpty)
        #expect(!result.skipped.isEmpty, "理由なく黙って見送っている")
    }

    /// 権限が無い（403）ときも同じ——「無い」とは違う。
    @Test("権限エラーで照合できない回も、写真を消さない")
    func permissionDeniedVerificationNeverDeletes() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.failGetMetadata(matching: "a.jpg", status: 403)
        let deleter = AcceptingDeleter()

        _ = await service(server, deleter: deleter).execute(
            assets: [asset("ID-a", "a.jpg", november)], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in })

        #expect(deleter.deleted.isEmpty, "権限が無くて確かめられないのに削除した")
    }

    // MARK: - 消したあと、印が最終的に届く

    /// ⚠️ **本命**。写真はもう端末に無いので、印が届かなければ復元できない。
    /// 書けない状態が続いたあと、**状況が直れば再送で届く**こと。
    ///
    /// ⚠️ ここで 403（権限）を使うのは、429・5xx は**アップローダーが自力で 3 回まで
    /// やり直す**（`DropboxBackupUploader.retryDelay`・2 秒 → 4 秒）ため、
    /// 「1 回の呼び出しで失敗して終わる」状態を作れないから。一時的なレート制限は
    /// アプリが自分で吸収する——その確認は下の別テストで行う。
    @Test("印が書けない状態が続いても、直れば再送で届く")
    func markersConvergeAfterFailures() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.failUploads(matching: "/.mosaic/meta/", status: 403)
        let deleter = AcceptingDeleter()
        let service = service(server, deleter: deleter)

        // 1 回目: 写真は消えるが、印は書けない。
        let result = await service.execute(
            assets: [asset("ID-a", "a.jpg", november)], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(result.deleted == ["ID-a"], "照合は通っているのに削除されていない")
        #expect(await restorableIDs(server).isEmpty, "前提: この時点では復元できない")

        // 再送（台帳を出典に送り直す＝`retryPendingOffloadMarkers` 相当）: まだ書けない。
        var written = await service.uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)],
                                                         token: "t")
        #expect(written.isEmpty, "書けていないのに送信済みにした（以後 再送されない）")

        // 状況が直る（権限が戻る / レート制限が明ける）。
        await server.clearFailures()
        written = await service.uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)],
                                                     token: "t")
        #expect(written == ["ID-a"])
        #expect(await restorableIDs(server) == ["ID-a"],
                "再送しても復元できない＝消した写真が取り戻せない")
    }

    /// 一時的なレート制限（429）は、**アプリが自力で吸収する**（3 回まで・2 秒 → 4 秒）。
    /// ⚠️ この 1 本だけ退避待ちで数秒かかる。確かめているのは「待ってでも印を届ける」こと——
    /// 印を落とすと写真が復元できなくなるので、ここは時間をかけてよい場所。
    @Test("一時的なレート制限は、1 回の送信の中で吸収して印を届ける")
    func transientRateLimitIsAbsorbed() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        // シャード 1 回・カタログ 1 回だけ 429（どちらも 2 回目の試行で通る）。
        await server.failUploads(matching: "/.mosaic/", status: 429, times: 2)

        let written = await service(server, deleter: AcceptingDeleter())
            .uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)], token: "t")

        #expect(written == ["ID-a"], "やり直せば通る 429 で諦めている")
        #expect(await restorableIDs(server) == ["ID-a"])
    }

    /// 片方の月だけ失敗したら、**その月の ID だけ**が未送信で残ること。
    /// まとめて「送信済み」にすると、書けていない月の写真が永久に復元できなくなる。
    @Test("月ごとに独立して失敗する（書けた月だけ送信済みになる）")
    func partialFailureIsPerShard() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.upload(path: photoPath("b.jpg", date: may), data: photoData)
        await server.failUploads(matching: "meta/2014-05", status: 403)
        let service = service(server, deleter: AcceptingDeleter())

        let written = await service.uploadOffloadMarkers(
            for: [target("ID-a", "a.jpg", november), target("ID-b", "b.jpg", may)], token: "t")

        #expect(written == ["ID-a"], "書けていない月まで送信済みにした: \(written)")
        #expect(await restorableIDs(server) == ["ID-a"])
    }

    /// カタログだけ書けなかった回も「送信済み」にしない——
    /// 載っていないシャードは読まれないので、印は在っても届かない。
    @Test("カタログだけ失敗した回も、再送でちゃんと届く")
    func catalogFailureRecoversOnRetry() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.failUploads(matching: "catalog.json", status: 403)
        let service = service(server, deleter: AcceptingDeleter())

        let first = await service.uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)],
                                                       token: "t")
        #expect(first.isEmpty, "カタログに載っていないのに送信済みにした")

        await server.clearFailures()
        let second = await service.uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)],
                                                        token: "t")
        #expect(second == ["ID-a"])
        #expect(await restorableIDs(server) == ["ID-a"], "再送でも届いていない")
    }

    /// ⚠️ 既にある月のシャードへ**別の写真の印を足す**ときも、既存の印を消さない。
    /// （download → merge → upload の merge を取り違えると、先に消した写真が失われる）
    @Test("同じ月へ 2 枚目の印を足しても、1 枚目が消えない")
    func addingToAnExistingShardKeepsEarlierMarkers() async {
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.upload(path: photoPath("b.jpg", date: november), data: photoData)
        let service = service(server, deleter: AcceptingDeleter())

        _ = await service.uploadOffloadMarkers(for: [target("ID-a", "a.jpg", november)], token: "t")
        _ = await service.uploadOffloadMarkers(for: [target("ID-b", "b.jpg", november)], token: "t")

        #expect(await restorableIDs(server) == ["ID-a", "ID-b"],
                "あとから足した印が、先の印を消した")
    }
}
