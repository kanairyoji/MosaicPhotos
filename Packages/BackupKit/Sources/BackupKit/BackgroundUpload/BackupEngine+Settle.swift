import DropboxCore
import Foundation
import MosaicSupport

/// 背景アップロードの応答を台帳へ落とす（ADR-181）。
///
/// 前面経路の `uploadOne` の後半（メタデータのジャーナル → 記録）と**同じ順序・同じ不変条件**。
/// 違いは材料を `PHAsset` ではなく `UploadSpool.Job`（投入時の意図）から取ること——
/// 応答が届く頃には別プロセスかもしれず、写真も端末から消えているかもしれない。
extension BackupEngine: BackgroundUploadSession.Settler {

    /// - Returns: 記録できたか。false のとき呼び出し側は spool を残す（次の窓で上げ直し・409 経由で照合）。
    public func settle(job: UploadSpool.Job, savedPath: String, contentHash: String) async -> Bool {
        let pendingStore = PendingMetadataStore(account: await runnerAccountFingerprint(),
                                                folder: job.backupRoot)
        let ok = await BackgroundSettlement.perform(
            job: job, savedPath: savedPath,
            journal: { shard, path, entry in pendingStore.appendEntry(shard: shard, path: path, entry: entry) },
            record: { [self] in
                await store().upsertRecord(
                    dropboxPath: savedPath, localIdentifier: job.localIdentifier,
                    filename: job.filename, creationDate: job.creationDate, contentHash: contentHash,
                    people: job.entry.people, albums: job.entry.albums, isFavorite: job.entry.isFavorite)
            })
        guard ok else {
            Diagnostics.mark("backup(bg): settle failed — \(job.filename)")
            return false
        }
        backedUpIDs.insert(job.localIdentifier)
        invalidateStatus()
        addLog("  ✓ \(job.filename) uploaded in background (hash verified)")
        return true
    }
}

/// 「メタデータのジャーナル → 記録」の順序を固定した純ロジック（ADR-171 と同じ不変条件）。
///
/// ⚠️ 逆順だと中断時に「写真は済み・メタデータ無し」が確定する。ジャーナルに書けなければ
/// 記録もしない（次の窓で上げ直す）。
enum BackgroundSettlement {
    static func perform(job: UploadSpool.Job, savedPath: String,
                        journal: (_ shard: String, _ path: String, _ entry: DropboxBackupMetadata.Entry) -> Bool,
                        record: () async -> Bool) async -> Bool {
        guard journal(BackupMetadataV2.shardName(for: job.creationDate), savedPath, job.entry) else { return false }
        return await record()
    }
}
