import DropboxCore
import Foundation
import Testing
@testable import BackupKit

/// オフロードの印の**往復**（ADR-200）。状態を持つ偽 Dropbox（`FakeDropboxServer`）へ
/// 実際に書き、**読む側と同じ手順**で辿り直して、印が見つかることを確かめる。
///
/// ## なぜ往復まで通すか
/// 「正しいパスへ上げた」だけのテストは、**読む側の手順を 1 つでも取り違えていると通ってしまう**。
/// 実際この不具合は二重だった——書き先（年月フォルダの下）とカタログ未登録。前者だけを
/// 直したテストは緑になり、後者は残る。読む側は必ず
/// 「`catalog.json` を読む → そこに載っているシャードだけを開く」という順に辿るので、
/// テストも**その順で**辿る。
///
/// ⚠️ この確認は実機の Z0（`device-verification.md`）の代わりにはならない（本物の Dropbox の
/// 挙動・権限・レート制限までは再現しない）。ただし「アプリの中で筋が通っているか」は
/// ここで閉じられる。
@Suite("オフロードの印の往復（書いて、読む側の手順で辿れる）")
@MainActor
struct OffloadMarkerRoundTripTests {

    private let root = "/MosaicPhotos/iPhone-E7/Backup"
    private let photoData = Data("photo-bytes".utf8)
    private var photoHash: String { DropboxContentHash.hash(of: photoData) }

    /// ADR-176 のレイアウト（`<root>/<年>/<年-月>/<名前>`）。
    private func photoPath(_ name: String, date: Date) -> String {
        let shard = BackupMetadataV2.shardName(for: date)
        return "\(root)/\(shard.prefix(4))/\(shard)/\(name)"
    }

    private func asset(id: String, name: String, date: Date) -> OffloadableAsset {
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

    /// **読む側と同じ手順**で印つきのエントリを集める。
    /// カタログに載っていないシャードは開かない——そこが今回の不具合の片方だった。
    private func offloadCandidatesAsTheAppWouldRead(
        _ server: FakeDropboxServer
    ) async -> [(localIdentifier: String, dropboxPath: String, albums: [String],
                 captureDate: Date?, contentHash: String?)] {
        let uploader = DropboxBackupUploader(httpClient: server)
        guard let catalogData = await uploader.download(path: root + BackupMetadataV2.catalogSuffix,
                                                        token: "t"),
              let catalog = try? JSONDecoder().decode(BackupCatalog.self, from: catalogData)
        else { return [] }
        var entries: [String: DropboxBackupMetadata.Entry] = [:]
        for shard in catalog.shards {
            guard let data = await uploader.download(path: root + BackupMetadataV2.shardSuffix(shard),
                                                     token: "t"),
                  let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: data)
            else { continue }
            entries.merge(decoded.entries) { _, new in new }
        }
        return BackupMetadataPlanning.offloadCandidates(from: entries)
    }

    private func service(_ server: FakeDropboxServer, deleter: PhotoDeleter) -> OffloadService {
        OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                       tokenProvider: FakeTokenProvider(), deleter: deleter,
                       backupRoot: root, log: { _ in })
    }

    /// 端末から消すところまで含めた一連の流れ（ADR-40）を通し、読み直せることを確かめる。
    @Test("オフロードを実行すると、読む側の手順で印にたどり着ける")
    func markerSurvivesTheRoundTrip() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: date), data: photoData)
        let deleter = AcceptingDeleter()

        let result = await service(server, deleter: deleter).execute(
            assets: [asset(id: "ID-a", name: "a.jpg", date: date)], limit: 10,
            recordLedger: { _ in true }, rollbackLedger: { _ in })

        #expect(result.deleted == ["ID-a"], "削除まで進んでいない: \(result.skipped)")

        let candidates = await offloadCandidatesAsTheAppWouldRead(server)
        #expect(candidates.count == 1,
                """
                読む側の手順（catalog → shards）で印にたどり着けない。
                書き先かカタログ登録のどちらかが欠けている＝再インストール後に復元できない。
                """)
        #expect(candidates.first?.localIdentifier == "ID-a")
        #expect(candidates.first?.dropboxPath == photoPath("a.jpg", date: date))
        #expect(candidates.first?.albums == ["旅行"], "アルバムの所属が印に載っていない")
    }

    /// 撮影月が違えばシャードも分かれる。**両方**がカタログに載っていないと、
    /// 片方の月の写真だけが復元できない（気づきにくい欠け方）。
    @Test("複数の月にまたがっても、すべてのシャードがカタログに載る")
    func everyTouchedShardIsReadable() async {
        let november = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11
        let may = Date(timeIntervalSince1970: 1_400_000_000)        // 2014-05
        let server = FakeDropboxServer()
        await server.upload(path: photoPath("a.jpg", date: november), data: photoData)
        await server.upload(path: photoPath("b.jpg", date: may), data: photoData)

        let written = await service(server, deleter: AcceptingDeleter()).uploadOffloadMarkers(
            for: [OffloadMarkerTarget(localIdentifier: "ID-a",
                                      dropboxPath: photoPath("a.jpg", date: november),
                                      albums: [], captureDate: november),
                  OffloadMarkerTarget(localIdentifier: "ID-b",
                                      dropboxPath: photoPath("b.jpg", date: may),
                                      albums: [], captureDate: may)],
            token: "t")

        #expect(Set(written) == ["ID-a", "ID-b"])
        let ids = Set(await offloadCandidatesAsTheAppWouldRead(server).map(\.localIdentifier))
        #expect(ids == ["ID-a", "ID-b"], "片方の月だけ読めない（カタログに載っていない）: \(ids)")
    }

    /// ⚠️ 印を書いた**あと**に、同じ写真のバックアップのエントリが流れてくることがある
    /// （再送キューに残っていた分）。印は「起きた事実」なので、それで消えてはいけない。
    @Test("あとから来たバックアップのエントリが流れても、印は読み出せる")
    func markerSurvivesALaterBackupEntry() async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let path = photoPath("a.jpg", date: date)
        let server = FakeDropboxServer()
        await server.upload(path: path, data: photoData)
        _ = await service(server, deleter: AcceptingDeleter()).uploadOffloadMarkers(
            for: [OffloadMarkerTarget(localIdentifier: "ID-a", dropboxPath: path,
                                      albums: [], captureDate: date)],
            token: "t")

        // 再送キューに残っていた（印を知らない）エントリが、あとから同じシャードへ流れる。
        let store = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                        token: "t", root: root)
        await store.apply(
            byShard: ["2023-11": [path: DropboxBackupMetadata.Entry(
                people: ["太郎"], albums: ["旅行"], localIdentifier: "ID-a")]],
            facts: nil) { _ in }

        let candidates = await offloadCandidatesAsTheAppWouldRead(server)
        #expect(candidates.count == 1,
                "あとから来たバックアップのエントリが印を消した（復元できなくなる）")
        #expect(candidates.first?.localIdentifier == "ID-a")
    }
}
