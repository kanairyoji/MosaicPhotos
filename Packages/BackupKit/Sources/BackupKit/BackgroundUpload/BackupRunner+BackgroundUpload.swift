import DropboxCore
import Foundation
import MosaicSupport
import Photos

/// `BackupRunner` の背景アップロード経路（ADR-181・fire-and-forget）。
///
/// 前面経路（`uploadOne`）が「読む → 上げる → 応答を検証 → 記録」を 1 枚ずつ**窓の中で**
/// 完結させるのに対し、こちらは「読む → spool に置く → OS に渡す」までで手を離す。
/// 応答の検証と記録は `BackgroundUploadSession` → `BackupEngine.settle` が窓の外で行う。
extension BackupRunner {

    /// 何枚積むごとに OS へ渡すか（渡した分は窓が閉じても転送が続く）。
    static let spoolFlushEvery = 20

    /// 実行開始時の spool の状態。
    struct BackgroundPlan {
        /// OS が転送中（または応答待ち）の写真。この実行の対象から外す。
        var inFlight: Set<String> = []
        /// 背景で 409 を受けた写真。前面経路（hash 照合・autorename）で片付ける。
        var conflicts: Set<String> = []
    }

    /// spool を読み、転送中の写真と 409 の写真を分ける。409 のジョブは spool から消す
    /// （前面経路が端末の写真を読み直して上げるので、コピーはもう要らない）。
    func backgroundPlan() -> BackgroundPlan {
        var plan = BackgroundPlan()
        for job in spool.pendingJobs() {
            if job.conflict {
                plan.conflicts.insert(job.localIdentifier)
                spool.remove(id: job.id)
            } else {
                plan.inFlight.insert(job.localIdentifier)
            }
        }
        return plan
    }

    /// 1 枚を spool に置く（OS へはまだ渡さない＝`flushSpool`）。
    ///
    /// 前面経路と同じ材料（hash・保存先・メタデータ）を**ここで**確定して意図として書く。
    /// 応答が届く頃には PHAsset を読み直せない（削除・別プロセス）ため。
    func spoolOne(asset: PHAsset, fetched fetchResult: FetchDataResult,
                  index i: Int, total: Int, folder: String,
                  indexes: Indexes, tally: inout UploadTally) -> ItemOutcome {
        guard case .success(let data, let filename, _) = fetchResult else {
            if case .skipped(let filename, let reason) = fetchResult {
                addLog("[\(i+1)/\(total)] SKIP \(filename): \(reason)")
                tally.skippedRead += 1
            }
            return .skipped
        }
        // 上限（枚数・総量・空き容量）。上限に達したらこの窓は終わり。
        // ⚠️ `pendingJobs()` はディレクトリ走査なので 1 枚ごとに呼ばず、集計は tally 側で持つ。
        if tally.spoolJobCount == nil {
            let jobs = spool.pendingJobs()
            tally.spoolJobCount = jobs.count
            tally.spoolBytes = jobs.reduce(0) { $0 + $1.byteCount }
        }
        guard spoolPolicy.canSpool(jobCount: tally.spoolJobCount ?? 0, spooledBytes: tally.spoolBytes,
                                   nextBytes: data.count, freeBytes: spool.freeBytes())
        else { return .spoolFull }

        setPhase(.uploading(current: i + 1, total: total, filename: filename))
        let job = UploadSpool.Job.make(
            localIdentifier: asset.localIdentifier, filename: filename, data: data,
            backupRoot: folder, creationDate: asset.creationDate, isFavorite: asset.isFavorite,
            latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            people: indexes.people[asset.localIdentifier] ?? [],
            albums: indexes.albums[asset.localIdentifier] ?? [])
        guard spool.write(job: job, body: data) else {
            addLog("[\(i+1)/\(total)] ⚠️ could not spool \(filename) — leaving for next run")
            return .skipped
        }
        addLog("[\(i+1)/\(total)] \(filename) (\(data.count) bytes) → spool → \(job.dropboxPath)")
        tally.spooled += 1
        tally.spoolJobCount = (tally.spoolJobCount ?? 0) + 1
        tally.spoolBytes += data.count
        return .done
    }

    /// spool のジョブを OS の背景セッションへ渡す（重複投入は session 側が弾く）。
    func flushSpool(token: String, tally: UploadTally) async {
        guard let backgroundUploads, tally.spooled > 0 else { return }
        let n = await backgroundUploads.enqueuePending(token: token)
        if n > 0 {
            addLog("Handed \(n) upload(s) to the background session")
            Diagnostics.mark("backup(bg): handed \(n) upload(s) to the OS (spooled=\(tally.spooled))")
        }
    }
}
