import DropboxCore
import Foundation
import Photos
import Testing
@testable import BackupKit

// MARK: - 共通

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundUploadTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeJob(_ id: String = UUID().uuidString, localID: String = "L1", data: Data = Data("img".utf8),
                     attempts: Int = 0, conflict: Bool = false,
                     enqueuedAt: Date = Date(), creationDate: Date? = nil) -> UploadSpool.Job {
    var job = UploadSpool.Job.make(
        localIdentifier: localID, filename: "\(localID).jpg", data: data,
        backupRoot: "/MosaicPhotos/iPhone-X/Backup", creationDate: creationDate, isFavorite: false,
        latitude: nil, longitude: nil, isScreenshot: false, people: ["Alice"], albums: ["Trip"], now: enqueuedAt)
    job = UploadSpool.Job(id: id, localIdentifier: job.localIdentifier, filename: job.filename,
                          dropboxPath: job.dropboxPath, backupRoot: job.backupRoot,
                          expectedHash: job.expectedHash, byteCount: job.byteCount,
                          creationDate: job.creationDate, entry: job.entry, enqueuedAt: job.enqueuedAt,
                          attempts: attempts, conflict: conflict)
    return job
}

// MARK: - 意図（Job.make）

@Suite("Background upload — intent")
struct BackgroundUploadIntentTests {

    @Test("意図は前面経路と同じ材料を持つ（hash・撮影年月フォルダ・メタデータ）")
    func intentMatchesForegroundRules() {
        let date = ISO8601DateFormatter().date(from: "2024-03-15T10:00:00Z")!
        let data = Data("photo-bytes".utf8)
        let job = UploadSpool.Job.make(
            localIdentifier: "ABC/L0/001", filename: "IMG_1.jpg", data: data,
            backupRoot: "/MosaicPhotos/iPhone-X/Backup", creationDate: date, isFavorite: true,
            latitude: 35.0, longitude: 139.0, isScreenshot: false, people: ["Alice"], albums: ["Trip"])
        #expect(job.expectedHash == DropboxContentHash.hash(of: data))
        #expect(job.dropboxPath == "/MosaicPhotos/iPhone-X/Backup/2024/2024-03/IMG_1.jpg")
        #expect(job.byteCount == data.count)
        #expect(job.entry.people == ["Alice"])
        #expect(job.entry.albums == ["Trip"])
        #expect(job.entry.isFavorite == true)
        #expect(job.entry.contentHash == job.expectedHash)
        #expect(job.entry.localIdentifier == "ABC/L0/001")
        #expect(job.entry.latitude == 35.0)
        #expect(job.attempts == 0)
        #expect(job.conflict == false)
    }
}

// MARK: - spool

@Suite("Background upload — spool")
struct UploadSpoolTests {

    @Test("本体と意図を書き、読み戻し、消せる")
    func roundTrip() {
        let spool = UploadSpool(directory: tempDir())
        let job = makeJob("j1")
        #expect(spool.write(job: job, body: Data("img".utf8)))
        #expect(spool.job(id: "j1")?.expectedHash == job.expectedHash)
        #expect(FileManager.default.fileExists(atPath: spool.bodyURL(for: "j1").path))
        #expect(spool.pendingJobs().map(\.id) == ["j1"])
        spool.remove(id: "j1")
        #expect(spool.pendingJobs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: spool.bodyURL(for: "j1").path))
    }

    @Test("孤児（本体だけ・意図だけ）は一覧に出ず、掃除される")
    func orphansAreCleaned() throws {
        let spool = UploadSpool(directory: tempDir())
        #expect(spool.write(job: makeJob("ok"), body: Data("a".utf8)))
        // 意図だけ
        try JSONEncoder().encode(makeJob("intent-only")).write(to: spool.jobURL(for: "intent-only"))
        // 本体だけ
        try Data("b".utf8).write(to: spool.bodyURL(for: "body-only"))

        #expect(spool.pendingJobs().map(\.id) == ["ok"])
        #expect(!FileManager.default.fileExists(atPath: spool.jobURL(for: "intent-only").path))
        #expect(!FileManager.default.fileExists(atPath: spool.bodyURL(for: "body-only").path))
    }

    @Test("一覧は投入順（enqueuedAt 昇順）")
    func pendingIsOrdered() {
        let spool = UploadSpool(directory: tempDir())
        let t0 = Date(timeIntervalSince1970: 1_000)
        spool.write(job: makeJob("late", enqueuedAt: t0.addingTimeInterval(10)), body: Data("x".utf8))
        spool.write(job: makeJob("early", enqueuedAt: t0), body: Data("x".utf8))
        #expect(spool.pendingJobs().map(\.id) == ["early", "late"])
    }

    @Test("update は試行回数・conflict を残す")
    func updatePersistsFlags() {
        let spool = UploadSpool(directory: tempDir())
        var job = makeJob("j")
        spool.write(job: job, body: Data("x".utf8))
        job.attempts = 2
        job.conflict = true
        spool.update(job: job)
        #expect(spool.job(id: "j")?.attempts == 2)
        #expect(spool.job(id: "j")?.conflict == true)
    }
}

// MARK: - 積む上限

@Suite("Background upload — policy")
struct BackgroundUploadPolicyTests {

    @Test("枚数・総量・空き容量のどれかが足りなければ積まない")
    func caps() {
        let policy = BackgroundUploadPolicy(maxJobs: 2, maxBytes: 100, minFreeBytes: 1_000)
        #expect(policy.canSpool(jobCount: 0, spooledBytes: 0, nextBytes: 50, freeBytes: 10_000))
        #expect(!policy.canSpool(jobCount: 2, spooledBytes: 0, nextBytes: 1, freeBytes: 10_000), "枚数上限")
        #expect(!policy.canSpool(jobCount: 0, spooledBytes: 60, nextBytes: 50, freeBytes: 10_000), "総量上限")
        #expect(!policy.canSpool(jobCount: 0, spooledBytes: 0, nextBytes: 50, freeBytes: 1_040), "空きが下限を割る")
        #expect(!policy.canSpool(jobCount: 0, spooledBytes: 0, nextBytes: 50, freeBytes: nil), "空きが読めなければ積まない")
    }
}

// MARK: - 投入の振り分け

@Suite("Background upload — enqueue split")
struct BackgroundUploadSplitTests {

    @Test("転送中と 409 待ちは触らず、上限に達したものは諦める")
    func split() {
        let fresh = makeJob("fresh")
        let running = makeJob("running")
        let conflict = makeJob("conflict", conflict: true)
        let exhausted = makeJob("exhausted", attempts: BackgroundUploadSession.maxAttempts)
        let retry = makeJob("retry", attempts: BackgroundUploadSession.maxAttempts - 1)

        let result = BackgroundUploadSession.split(pending: [fresh, running, conflict, exhausted, retry],
                                                   running: ["running"])
        #expect(Set(result.enqueue.map(\.id)) == ["fresh", "retry"])
        #expect(result.giveUp.map(\.id) == ["exhausted"])
    }

    @Test("1 回に渡す数には上限がある（diagnostics-81: 813 件を一気に渡して 429 の嵐）")
    func enqueueIsCapped() {
        let jobs = (0..<100).map { makeJob("j\($0)") }
        let result = BackgroundUploadSession.split(pending: jobs, running: [], excluded: [],
                                                   limit: BackgroundUploadSession.maxEnqueuePerFlush)
        #expect(result.enqueue.count == BackgroundUploadSession.maxEnqueuePerFlush)
        #expect(result.giveUp.isEmpty)
        // 上限は「渡す数」だけを絞る。諦め（上限回数超過）は件数に関係なく拾う。
        let withExhausted = jobs + [makeJob("dead", attempts: BackgroundUploadSession.maxAttempts)]
        let r2 = BackgroundUploadSession.split(pending: withExhausted, running: [], excluded: [], limit: 5)
        #expect(r2.enqueue.count == 5)
        #expect(r2.giveUp.map(\.id) == ["dead"])
    }

    /// ⚠️ **数ではなく「同時数」で絞る**（実機 diagnostics-82）。
    /// 1 回に渡す数を 813 → 40 に減らしても 429 は消えなかった。出ていたのは
    /// `too_many_write_operations`＝**同じ名前空間への同時書き込み**で、40 を一度に渡せば
    /// 40 が同時に同じフォルダへ書きに行く。4.5 時間で 429 が 862 回・成功 0 枚だった。
    @Test("転送中のぶんを差し引いて、同時に走る数を抑える")
    func enqueueCapacityAccountsForRunningTransfers() {
        let maxInFlight = BackgroundUploadSession.maxInFlight
        #expect(BackgroundUploadSession.enqueueCapacity(running: 0) == maxInFlight,
                "空いているのに渡さないのは遅いだけ")
        #expect(BackgroundUploadSession.enqueueCapacity(running: maxInFlight - 1) == 1)
        #expect(BackgroundUploadSession.enqueueCapacity(running: maxInFlight) == 0,
                "上限まで走っているのに追加で渡している（同時書き込みが増える）")
        #expect(BackgroundUploadSession.enqueueCapacity(running: maxInFlight + 10) == 0,
                "負の数を渡そうとしている")
        // 1 回に渡す上限の方が小さければ、そちらが効く。
        #expect(BackgroundUploadSession.enqueueCapacity(running: 0, maxInFlight: 100, perFlush: 5) == 5)
    }

    /// ⚠️ **待てと言われたら、待ってから自分で出し直す**（実機 diagnostics-82）。
    /// Dropbox は `retry_after: 1`（1 秒）を返していたのに、投入の口がバックアップ実行中の
    /// `flushSpool` しか無く、次の投入は**次の窓＝30 分後**だった。結果、同じ写真が
    /// 30 分ごとに 1 回だけ試されては 429 を受け、4.5 時間で 1 枚も上がらなかった。
    @Test("レート制限の間は出し直さず、明けたら自分で出しに行く")
    func topUpWaitsWhileRateLimitedThenResumes() async {
        final class Calls: @unchecked Sendable { var count = 0 }
        let calls = Calls()
        // (1) レート制限中は、トークンを取りに行きもしない。
        let limited = BackgroundUploadSession(spool: UploadSpool(directory: tempDir()))
        limited.tokenProvider = { calls.count += 1; return nil }   // nil＝ここで止まる（OS へは渡さない）
        limited.noteRateLimited(retryAfter: 60)
        await limited.scheduleTopUp()?.value
        #expect(calls.count == 0, "待てと言われている間に出し直している（429 が増えるだけ）")

        // (2) 制限が無ければ、自分から出し直しに行く。
        // ⚠️ 同じセッションで「明けた」を作ることはできない——待ちは**短縮しない**
        // （`noteRateLimited` は今より遠い時刻しか受け付けない）。それが正しい仕様なので、
        // テストの方を分ける。
        let free = BackgroundUploadSession(spool: UploadSpool(directory: tempDir()))
        free.tokenProvider = { calls.count += 1; return nil }
        await free.scheduleTopUp()?.value
        #expect(calls.count == 1, "誰も出し直さない（次の窓まで 30 分止まる）")
    }

    @Test("台帳へ書いている最中・この枠で投入済みのジョブは再投入しない（diagnostics-74 の重複投入）")
    func settlingAndAttemptedAreExcluded() {
        let settling = makeJob("settling")
        let attempted = makeJob("attempted", attempts: 1)
        let fresh = makeJob("fresh")
        let result = BackgroundUploadSession.split(pending: [settling, attempted, fresh], running: [],
                                                   excluded: ["settling", "attempted"])
        #expect(result.enqueue.map(\.id) == ["fresh"])
        #expect(result.giveUp.isEmpty)
    }
}

// MARK: - 応答の分類（ADR-40 を崩さない）

@Suite("Background upload — response")
struct BackgroundUploadResponseTests {

    private let job = makeJob("j", data: Data("img".utf8))

    @Test("200 ＋ hash 一致だけが「済み」")
    func settleOnlyOnHashMatch() {
        let body = Data(#"{"content_hash":"\#(job.expectedHash)","path_lower":"/x/y.jpg"}"#.utf8)
        #expect(BackgroundUploadSession.classify(job: job, status: 200, body: body, failed: false)
                == .settle(savedPath: "/x/y.jpg", contentHash: job.expectedHash))
    }

    @Test("200 でも hash 不一致は再投入（済みにしない）")
    func mismatchRetries() {
        let body = Data(#"{"content_hash":"deadbeef","path_lower":"/x/y.jpg"}"#.utf8)
        #expect(BackgroundUploadSession.classify(job: job, status: 200, body: body, failed: false)
                == .retry(reason: "hash mismatch"))
    }

    @Test("429 は失敗ではない — 待ち時間つきで出し直す（試行回数を食わない）")
    func rateLimitIsNotAFailure() {
        // ヘッダの Retry-After を尊重する。
        #expect(BackgroundUploadSession.classify(job: job, status: 429, body: Data(), failed: false,
                                                 retryAfterHeader: "12")
                == .rateLimited(retryAfter: 12))
        // ヘッダが無ければ本文の retry_after（Dropbox の形）。
        let body = Data(#"{"error":{"reason":{".tag":"too_many_write_operations"},"retry_after":7}}"#.utf8)
        #expect(BackgroundUploadSession.classify(job: job, status: 429, body: body, failed: false)
                == .rateLimited(retryAfter: 7))
        // どちらも無ければ既定値。
        #expect(BackgroundUploadSession.classify(job: job, status: 429, body: Data(), failed: false)
                == .rateLimited(retryAfter: BackgroundUploadSession.defaultRetryAfterSeconds))
    }

    @Test("待ち時間は常識的な範囲にクランプする（0 秒連打・暴走した指定を鵜呑みにしない）")
    func retryAfterIsClamped() {
        #expect(BackgroundUploadSession.retryAfterSeconds(from: "0", body: Data()) >= 1)
        #expect(BackgroundUploadSession.retryAfterSeconds(from: "99999", body: Data())
                == BackgroundUploadSession.maxRetryAfterSeconds)
        #expect(BackgroundUploadSession.retryAfterSeconds(from: "not-a-number", body: Data())
                == BackgroundUploadSession.defaultRetryAfterSeconds)
    }

    @Test("409 は前面経路へ、通信エラー・401・5xx は再投入")
    func othersRetryOrConflict() {
        #expect(BackgroundUploadSession.classify(job: job, status: 409, body: Data(), failed: false) == .conflict)
        #expect(BackgroundUploadSession.classify(job: job, status: -1, body: Data(), failed: true)
                == .retry(reason: "transport error"))
        #expect(BackgroundUploadSession.classify(job: job, status: 401, body: Data(), failed: false)
                == .retry(reason: "HTTP 401"))
        #expect(BackgroundUploadSession.classify(job: job, status: 503, body: Data(), failed: false)
                == .retry(reason: "HTTP 503"))
    }
}

// MARK: - 台帳への落とし方（ADR-171 の順序）

@Suite("Background upload — settlement")
struct BackgroundSettlementTests {

    @Test("ジャーナル → 記録の順。ジャーナルに書けなければ記録しない")
    func journalFirst() async {
        let job = makeJob("j", creationDate: ISO8601DateFormatter().date(from: "2024-03-15T10:00:00Z"))
        var order: [String] = []
        let ok = await BackgroundSettlement.perform(job: job, savedPath: "/p.jpg",
            journal: { shard, path, entry in
                order.append("journal:\(shard):\(path):\(entry.people.joined())"); return true },
            record: { order.append("record"); return true })
        #expect(ok)
        #expect(order == ["journal:2024-03:/p.jpg:Alice", "record"])

        var recorded = false
        let failed = await BackgroundSettlement.perform(job: job, savedPath: "/p.jpg",
            journal: { _, _, _ in false },
            record: { recorded = true; return true })
        #expect(!failed)
        #expect(!recorded, "ジャーナル失敗なのに記録された")
    }

    @Test("記録に失敗したら false（spool を残して上げ直す）")
    func recordFailurePropagates() async {
        let ok = await BackgroundSettlement.perform(job: makeJob(), savedPath: "/p.jpg",
            journal: { _, _, _ in true }, record: { false })
        #expect(!ok)
    }
}

// MARK: - runner の起動時計画

/// runner の delegate スタブ（この suite では呼ばれない）。
@MainActor
private final class NoopRunnerDelegate: BackupRunnerDelegate {
    func runnerSetPhase(_ phase: BackupEngine.Phase) {}
    func runnerLog(_ message: String) {}
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?) async -> Bool { true }
    func runnerRecordedLocalIdentifiers() async -> Set<String> { [] }
    func runnerPriorityLocalIdentifiers() async -> Set<String> { [] }
    func runnerAccountFingerprint() async -> String? { nil }
}

private final class StubToken: AccessTokenProvider {
    func freshAccessToken() async throws -> String { "tok" }
}

private final class RecordingEnqueuer: BackgroundUploadEnqueuing, @unchecked Sendable {
    var calls = 0
    func beginRun() {}
    func enqueuePending(token: String) async -> Int { calls += 1; return 0 }
}

@Suite("Background upload — runner plan")
@MainActor
struct BackupRunnerBackgroundPlanTests {

    @Test("転送中は対象外、409 待ちは前面経路へ（spool から外す）")
    func planSplitsSpool() {
        let spool = UploadSpool(directory: tempDir())
        spool.write(job: makeJob("a", localID: "L-a"), body: Data("x".utf8))
        spool.write(job: makeJob("b", localID: "L-b", conflict: true), body: Data("x".utf8))
        let runner = BackupRunner(tokenProvider: StubToken(),
                                  uploader: DropboxBackupUploader(httpClient: URLSessionHTTPClient()),
                                  progressStore: BackupProgressStore(), uploadLimit: { 0 },
                                  delegate: NoopRunnerDelegate(),
                                  backgroundUploads: RecordingEnqueuer(), spool: spool,
                                  useBackgroundUploads: { true })
        let plan = runner.backgroundPlan()
        #expect(plan.inFlight == ["L-a"])
        #expect(plan.conflicts == ["L-b"])
        #expect(spool.pendingJobs().map(\.id) == ["a"], "409 待ちのコピーは前面経路が読み直すので消す")
    }

    @Test("この実行で何も積まなくても、残っている spool は OS へ渡す（前の窓の取り残し）")
    func flushIsUnconditional() async {
        let enqueuer = RecordingEnqueuer()
        let runner = BackupRunner(tokenProvider: StubToken(),
                                  uploader: DropboxBackupUploader(httpClient: URLSessionHTTPClient()),
                                  progressStore: BackupProgressStore(), uploadLimit: { 0 },
                                  delegate: NoopRunnerDelegate(),
                                  backgroundUploads: enqueuer, spool: UploadSpool(directory: tempDir()),
                                  useBackgroundUploads: { true })
        await runner.flushSpool(token: "tok")
        #expect(enqueuer.calls == 1, "積んだ分が無い窓で渡さないと、前の窓の取り残しが永久に残る")
    }
}


// MARK: - メタデータ書き込みの再試行（429/5xx）

@Suite("Metadata upload retry")
struct MetadataUploadRetryTests {

    @Test("429 と 5xx だけ、最大 3 回。Retry-After があれば従う（上限 30 秒）")
    func retryPolicy() {
        #expect(DropboxBackupUploader.retryDelay(status: 429, attempt: 1, retryAfter: nil) == 2)
        #expect(DropboxBackupUploader.retryDelay(status: 429, attempt: 2, retryAfter: nil) == 4)
        #expect(DropboxBackupUploader.retryDelay(status: 429, attempt: 3, retryAfter: nil) == nil, "3 回目で諦める")
        #expect(DropboxBackupUploader.retryDelay(status: 503, attempt: 1, retryAfter: "5") == 5)
        #expect(DropboxBackupUploader.retryDelay(status: 429, attempt: 1, retryAfter: "600") == 30, "上限 30 秒")
        #expect(DropboxBackupUploader.retryDelay(status: 409, attempt: 1, retryAfter: nil) == nil, "409 は再試行しない")
        #expect(DropboxBackupUploader.retryDelay(status: 401, attempt: 1, retryAfter: nil) == nil)
    }
}
