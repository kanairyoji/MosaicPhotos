import DropboxCore
import Foundation
@testable import BackupKit

/// **テスト用の「バックアップの 1 回」**（`BackupRunner.run` の写し・判断は本番の関数）。
///
/// PHAsset の列挙・読み込みは macOS のテストで使えないので、配管だけを写す。
/// ⚠️⚠️ **写しは 1 つだけにする**（ADR-277）。以前は `SharedOnlyBackupScenarioTests` と
/// `FamilySharingScenarioTests` に 1 つずつ写しがあり、**どちらも本番からずれていた**
/// ——本番は「済み」を **進捗台帳 ∪ 記録** で引くのに、写しは記録だけで引いていた。
/// そのため「台帳にだけ載って記録が無い写真が、共有で永久に待たされる」（実機ログ diagnostics-108）が
/// テストの世界に**存在し得なかった**。写しを 2 つ持てば、また片方だけがずれる。
/// 判断（`BackupScopePolicy.progress` / `hasWork` / `candidateRestriction` / `uploadTargets`）は
/// 本番と同じ関数を呼び、台帳（`ledger`）も本番と同じく「記録できた写真だけ」を足す。
/// ⚠️ 限界: 照合（reconcile）が台帳を書き直すところは写していない（`ledger` は照合で変わらない）。
@MainActor
enum BackupPassForTesting {

    struct Photo {
        let id: String
        let data: Data
        let taken: Date
    }

    /// 上げた ID を返す。`ledger` は進捗台帳の写し（本番の `BackupProgressStore`）。
    static func run(library: [Photo], ledger: inout Set<String>, store: BackupStore,
                    engine: BackupEngine, http: HTTPClient, limit: Int = 0,
                    path: (Photo) -> String) async -> [String] {
        let scope = BackupScope.current(.standard)
        let (done, awaited) = BackupScopePolicy.progress(
            ledger: ledger, recorded: await store.recordedLocalIdentifiers(),
            shareMembers: await engine.runnerShareMemberLocalIdentifiers())
        guard BackupScopePolicy.hasWork(scope: scope, awaitedCount: awaited.count) else { return [] }
        let restriction = BackupScopePolicy.candidateRestriction(scope: scope, awaitedByShare: awaited)
        let candidates = library.filter { restriction?.contains($0.id) ?? true }
        let plan = BackupScopePolicy.uploadTargets(
            library: candidates.map(\.id), alreadyUploaded: done, awaitedByShare: awaited,
            scope: scope, limit: limit)
        let uploader = DropboxBackupUploader(httpClient: http)
        var uploaded: [String] = []
        for id in plan.pending {
            guard let photo = library.first(where: { $0.id == id }) else { continue }
            let target = path(photo)
            let localHash = DropboxContentHash.hash(of: photo.data)
            var result = await uploader.upload(data: photo.data, to: target, token: "t",
                                               expectedHash: localHash, clientModified: photo.taken)
            // 本番と同じく、409 は中身を照合して同じなら「上がっている」とみなす（記録だけ作る）。
            if result == .alreadyExists,
               let remote = await uploader.getMetadata(path: target, token: "t"),
               remote.contentHash == localHash {
                result = .uploaded(path: target.lowercased(), contentHash: localHash)
            }
            // 本番と同じく、確かに上がったときだけ記録し、記録できたときだけ台帳へ入れる。
            guard case .uploaded(let saved, let hash) = result else { continue }
            _ = await store.upsertRecord(dropboxPath: saved, localIdentifier: id,
                                         filename: "\(id).jpg", creationDate: photo.taken,
                                         contentHash: hash, people: [], albums: [],
                                         isFavorite: false)
            ledger.insert(id)
            uploaded.append(id)
        }
        return uploaded
    }
}
