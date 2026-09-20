import DropboxCore
import DropboxTestSupport
import Foundation
import Testing
@testable import BackupKit

/// **照合（reconcile）が写真を見失わせないこと**（ADR-166）。
///
/// 照合は「Dropbox の実ファイル一覧」と台帳を突き合わせ、実体の無い記録を消す。
/// 正しく働けばバックアップの穴を見つけられるが、**一覧が不完全なまま判断すると
/// 実在する写真の記録まで消す**——オフロード済みの写真なら、アプリからも見えなくなる。
/// ここでは偽 Dropbox のページングと障害注入で、その境目を固定する。
@Suite("照合の安全（不完全な一覧で記録を消さない）")
struct ReconcileScenarioTests {

    private let root = "/MosaicPhotos/iPhone-E7/Backup"

    private func seed(_ server: FakeDropboxServer, count: Int) async -> [String: String] {
        // ⚠️ 本物の Dropbox と同じく、**フォルダ自体が在る**状態にする
        //（無いと `list_folder` は not_found＝「ファイル 0 件」になり、別の経路を試してしまう）。
        await server.seed(root, hash: "", isFolder: true)
        var expected: [String: String] = [:]
        for index in 0..<count {
            let path = "\(root)/2023/2023-11/p\(index).jpg"
            let data = Data("photo-\(index)".utf8)
            await server.upload(path: path, data: data)
            expected[path.lowercased()] = DropboxContentHash.hash(of: data)
        }
        return expected
    }

    // MARK: - 一覧が全部取れたときだけ判断する

    /// ⚠️ **本命**。2 ページ目の取得が失敗した回に 1 ページ目を「全部」と読むと、
    /// 残りの記録がまとめて消える。`listFolder` は**部分的な結果を返してはいけない**
    /// （呼び出し側は nil を見て照合そのものを見送る）。
    @Test("ページの途中で失敗したら、一覧は nil を返す（部分結果を渡さない）")
    func partialListingIsNeverReturned() async {
        let server = FakeDropboxServer()
        _ = await seed(server, count: 5)
        await server.setPageSize(2)              // 3 ページに分かれる
        await server.setFailListFolderContinue(true)
        let uploader = DropboxBackupUploader(httpClient: server)

        let listing = await uploader.listFolder(root: root, token: "t")

        #expect(listing == nil,
                """
                途中で失敗したのに一覧を返した（\(listing?.count ?? 0) 件）。
                照合はこれを「Dropbox にはこれしか無い」と読み、残りの記録を消す
                ——オフロード済みの写真なら、アプリから見えなくなる。
                """)
    }

    @Test("ページが分かれていても、全ページを読み切れば全件そろう")
    func pagingCollectsEveryEntry() async {
        let server = FakeDropboxServer()
        let expected = await seed(server, count: 2_500)   // 既定ページ（2000）を跨ぐ
        let uploader = DropboxBackupUploader(httpClient: server)

        let listing = await uploader.listFolder(root: root, token: "t")

        #expect(listing?.count == expected.count,
                "ページを読み切れていない（\(listing?.count ?? 0)/\(expected.count)）")
        #expect(listing == expected, "内容が一致しない（hash の取り違え）")
    }

    /// 一覧が全部取れた回は、本来の働きどおり「実体の無い記録」を消す。
    @Test("一覧が揃っていれば、実体の無い記録だけを消す")
    func completeListingRemovesOnlyMissing() async {
        let server = FakeDropboxServer()
        let expected = await seed(server, count: 3)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        let past = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<3 {
            let path = "\(root)/2023/2023-11/p\(index).jpg"
            _ = await store.upsertRecord(dropboxPath: path, localIdentifier: "ID-\(index)",
                                     filename: "p\(index).jpg", creationDate: past,
                                     contentHash: expected[path.lowercased()],
                                     people: [], albums: [], isFavorite: false)
        }
        // 1 枚だけ Dropbox 側から消える（他端末・Web UI での削除）。
        await server.remove("\(root)/2023/2023-11/p1.jpg")
        let listing = await DropboxBackupUploader(httpClient: server)
            .listFolder(root: root, token: "t")

        let result = await store.reconcile(remote: listing ?? [:],
                                           listedAt: Date().addingTimeInterval(1))

        #expect(result.removed == 1, "消えた 1 枚だけを外していない（removed=\(result.removed)）")
        #expect(result.verified == ["ID-0", "ID-2"] as Set, "実在する記録まで落とした: \(result.verified)")
    }

    // MARK: - オフロード済みの写真の実体が消えたとき（現在の挙動を固定する）

    /// ⚠️ **唯一のコピーが消えた状態**。オフロード済みの写真を Dropbox 側で消すと、
    /// その写真はもうどこにも無い。いまのアプリはこれを**利用者に知らせない**——
    /// 照合はバックアップ記録を外すだけで、オフロード台帳（アルバム表示の出典）は触らない。
    /// つまりアルバムには出続け、開くと取得に失敗する。
    ///
    /// ここではその挙動を**固定**する（`unresolved-problems.md` に選択肢を残した）。
    /// 挙動を変えるときは、このテストを意図して書き換えること。
    @Test("オフロード済みの実体が消えても、照合はオフロード台帳を触らない（現在の挙動）")
    func reconcileLeavesTheOffloadLedgerAlone() async {
        let server = FakeDropboxServer()
        await server.seed(root, hash: "", isFolder: true)
        let path = "\(root)/2023/2023-11/gone.jpg"
        let data = Data("only-copy".utf8)
        await server.upload(path: path, data: data)
        let past = Date(timeIntervalSince1970: 1_000_000)
        let store = BackupStore(modelContainer: BackupStore.inMemoryContainerForTesting())
        _ = await store.upsertRecord(dropboxPath: path, localIdentifier: "ID-gone",
                                 filename: "gone.jpg", creationDate: past,
                                 contentHash: DropboxContentHash.hash(of: data),
                                 people: [], albums: ["旅行"], isFavorite: false)
        _ = await store.upsertOffloads([(localIdentifier: "ID-gone", dropboxPath: path,
                                         albums: ["旅行"], captureDate: past,
                                         contentHash: DropboxContentHash.hash(of: data))])

        // 利用者が Dropbox の Web UI で消した（唯一のコピーが失われる）。
        await server.remove(path)
        let listing = await DropboxBackupUploader(httpClient: server)
            .listFolder(root: root, token: "t")
        let result = await store.reconcile(remote: listing ?? [:],
                                           listedAt: Date().addingTimeInterval(1))

        #expect(result.removed == 1, "バックアップ記録は外れるはず")
        let snapshot = await store.offloadLedgerSnapshot()
        #expect(snapshot.count == 1,
                """
                現在の挙動が変わっている。オフロード台帳を照合が触るようになったなら、
                「アルバムから静かに消える」ことになるので、利用者への通知とセットで決めること
                （unresolved-problems.md「オフロード済みの写真の実体が消えても気づけない」）。
                """)
    }
}
