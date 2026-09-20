import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// **機種変更・再インストールの通し**（ADR-39/40・ADR-200）。
///
/// オフロードした写真は端末に無い。復元の手掛かりは Dropbox 上の `offloadedAt` の印**だけ**で、
/// 再インストール後は「印 → オフロード台帳」を建て直して初めてアルバムに戻る。
/// ここでは偽 Dropbox に実際に印を書き、**台帳を空にしてから**（＝新しい端末）
/// 読む側と同じ手順で辿って、台帳が建て直せることを通しで確かめる。
///
/// ⚠️ 同時に確かめるのは「**蘇らせてはいけないものを蘇らせない**」こと。
/// ユーザーが写真アプリで消した写真は印を持たないので、復元の対象に入ってはいけない
/// （入ると、消したはずの写真がアルバムに戻る）。
@Suite("機種変更後の台帳再構築（印から建て直せる）")
@MainActor
struct OffloadRestoreScenarioTests {

    private let root = "/MosaicPhotos/iPhone-E7/Backup"
    private let photoData = Data("photo-bytes".utf8)

    private func path(_ name: String, _ date: Date) -> String {
        let shard = BackupMetadataV2.shardName(for: date)
        return "\(root)/\(shard.prefix(4))/\(shard)/\(name)"
    }

    private func asset(_ id: String, _ name: String, _ date: Date,
                       albums: [String]) -> OffloadableAsset {
        OffloadableAsset(localIdentifier: id, dropboxPath: path(name, date), filename: name,
                         albums: albums, captureDate: date, modificationDate: nil,
                         backedUpAt: Date(), isLivePhoto: false,
                         loadData: { [photoData] in (photoData, false) })
    }

    private final class AcceptingDeleter: PhotoDeleter, @unchecked Sendable {
        func delete(localIdentifiers: [String]) async -> Bool { true }
    }

    private func service(_ server: FakeDropboxServer) -> OffloadService {
        OffloadService(uploader: DropboxBackupUploader(httpClient: server),
                       tokenProvider: FakeTokenProvider(), deleter: AcceptingDeleter(),
                       backupRoot: root, log: { _ in })
    }

    /// 新しい端末がやること: カタログを読み、**載っているシャードだけ**を開いて 1 つにまとめる。
    private func metadataAsANewDeviceWouldRead(_ server: FakeDropboxServer) async
        -> DropboxBackupMetadata {
        let uploader = DropboxBackupUploader(httpClient: server)
        var merged = DropboxBackupMetadata()
        guard let data = await uploader.download(path: root + BackupMetadataV2.catalogSuffix,
                                                 token: "t"),
              let catalog = try? JSONDecoder().decode(BackupCatalog.self, from: data)
        else { return merged }
        for shard in catalog.shards {
            guard let d = await uploader.download(path: root + BackupMetadataV2.shardSuffix(shard),
                                                  token: "t"),
                  let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self, from: d)
            else { continue }
            merged = merged.merging(decoded.entries)
        }
        return merged
    }

    @Test("オフロードした写真は台帳を空にしても復元でき、ユーザー削除の写真は蘇らない")
    func rebuildsOnlyOffloadedPhotos() async {
        let may = Date(timeIntervalSince1970: 1_400_000_000)        // 2014-05
        let november = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11
        let server = FakeDropboxServer()
        await server.upload(path: path("a.jpg", may), data: photoData)
        await server.upload(path: path("b.jpg", november), data: photoData)
        await server.upload(path: path("c.jpg", november), data: photoData)

        // (1) 2 枚をオフロード（＝印が付く）。
        let result = await service(server).execute(
            assets: [asset("ID-a", "a.jpg", may, albums: ["旅行"]),
                     asset("ID-b", "b.jpg", november, albums: ["家族"])],
            limit: 10, recordLedger: { _ in true }, rollbackLedger: { _ in })
        #expect(Set(result.deleted) == ["ID-a", "ID-b"], "前提: 2 枚とも削除まで進む")

        // (2) 3 枚目はバックアップしただけ（ユーザーが写真アプリで消した＝印は付かない）。
        let store = BackupMetadataStore(uploader: DropboxBackupUploader(httpClient: server),
                                        token: "t", root: root)
        await store.apply(byShard: ["2023-11": [path("c.jpg", november):
            DropboxBackupMetadata.Entry(people: [], albums: ["家族"],
                                        localIdentifier: "ID-c")]], facts: nil) { _ in }

        // (3) 新しい端末（台帳は空）で読み直し、台帳を建て直す。
        let metadata = await metadataAsANewDeviceWouldRead(server)
        let candidates = BackupMetadataPlanning.offloadCandidates(from: metadata.entries)
        let fresh = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        #expect(await fresh.upsertOffloads(candidates), "台帳へ書き戻せていない")

        // (4) 復元された台帳の中身を確かめる。
        let snapshot = await fresh.offloadLedgerSnapshot()
        #expect(snapshot.count == 2,
                """
                復元された件数が合わない（\(snapshot.count)）。
                多ければユーザー削除の写真が蘇っており、少なければオフロードした写真を失っている。
                """)
        #expect(snapshot.byAlbum["旅行"]?.count == 1, "アルバムの所属が復元されていない")
        #expect(snapshot.byAlbum["家族"]?.count == 1)
        #expect(snapshot.byAlbum["家族"]?.contains(path("c.jpg", november)) != true,
                "ユーザーが消した写真がアルバムに蘇っている")
    }

    /// ⚠️ 月が増えてもカタログが**全部**を持ち続けること。1 つでも落ちると、
    /// その月にオフロードした写真だけが静かに復元できなくなる（気づきにくい欠け方）。
    @Test("多数の月にまたがっても、すべての月の印が復元できる")
    func everyMonthSurvives() async {
        let server = FakeDropboxServer()
        var targets: [OffloadMarkerTarget] = []
        var expected: Set<String> = []
        // 2022-01 から 14 か月ぶん（年をまたぐ）。
        var components = DateComponents(year: 2022, month: 1, day: 15)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for index in 0..<14 {
            components.month = 1 + index
            let date = calendar.date(from: components)!
            let name = "m\(index).jpg"
            await server.upload(path: path(name, date), data: photoData)
            targets.append(OffloadMarkerTarget(localIdentifier: "ID-\(index)",
                                               dropboxPath: path(name, date),
                                               albums: [], captureDate: date))
            expected.insert("ID-\(index)")
        }

        let written = await service(server).uploadOffloadMarkers(for: targets, token: "t")
        #expect(Set(written) == expected, "書けなかった月がある: \(written.count)/14")

        let metadata = await metadataAsANewDeviceWouldRead(server)
        let restored = Set(BackupMetadataPlanning.offloadCandidates(from: metadata.entries)
            .map(\.localIdentifier))
        #expect(restored == expected,
                "復元できない月がある（カタログに載っていないシャードは開かれない）: \(restored.count)/14")
    }
}
