import DropboxCore
import Foundation
import MosaicSupport

/// 背景 `URLSession` でのアップロード（ADR-181・fire-and-forget）。
///
/// ## 何が変わるか
/// 前面の `URLSession` は夜間ウィンドウ（約 5 分）の外へ出られず、1 窓 150〜300 枚が上限だった。
/// 背景セッションは **OS が転送を続ける**——アプリが休眠しても、終了しても、ウィンドウが
/// 閉じても。投入だけを窓の中で済ませ、完了は後日（別プロセス起動でも）受け取る。
///
/// ## 不変条件（ADR-40 を崩さない）
/// - 「済み」は**応答の `content_hash` が投入時の hash と一致したときだけ**付ける。
///   応答が来る前に台帳へ書かない。応答が届いたとき、意図は `UploadSpool` から読む。
/// - 応答が来ないまま spool に残ったジョブは、次の窓で**再投入**する（上限回数まで）。
///   spool が消えた（Caches の掃除）ジョブは、その写真が次回の対象に戻るだけで失うものは無い。
/// - **メタデータは応答の側で**ジャーナルへ書く（ADR-171）。写真本体が上がった証拠と一緒に。
///
/// ## 動作の骨格
/// ```
/// 窓の中（数秒／枚）                                   窓の外（OS 任せ）
///  読む → spool に書く → uploadTask を発行 ─── 転送 ───▶ 応答 → hash 照合 → 台帳「済み」
///                                                        → メタデータをジャーナルへ → spool 削除
/// ```
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` で起こされた
/// プロセスでは `attach(completion:)` を呼ぶ。セッションが（遅延）生成されて溜まっていた
/// 応答が流れ、台帳の更新が**すべて終わってから**完了ハンドラを呼ぶ（呼ばないと OS が
/// 次からアプリを起こさなくなる。早く呼ぶと台帳更新の途中で吊るされる）。
///
/// 台帳を更新する相手（`Settler`）は**非同期に解決**する（`settlerProvider`）。起こされた
/// プロセスではストア群がまだ無く、構築を待ってから書くため。
public final class BackgroundUploadSession: NSObject, @unchecked Sendable {

    public static let sessionIdentifier = "com.mosaicphotos.backup.upload"

    /// 応答を受け取った側が台帳を更新するための窓口（`BackupEngine` が実装）。
    public protocol Settler: AnyObject {
        /// hash が一致したアップロードの記録（メタデータのジャーナル → 台帳「済み」）。
        @MainActor func settle(job: UploadSpool.Job, savedPath: String, contentHash: String) async -> Bool
    }

    /// 1 ジョブぶんの再投入上限。これを超えたら諦めて spool を消す（次回の通常対象に戻る）。
    public static let maxAttempts = 3

    let spool: UploadSpool
    private let lock = NSLock()
    private var _session: URLSession?
    /// 応答ボディ（`files/upload` の JSON・数百バイト）をタスクごとに溜める。
    private var bodies: [Int: Data] = [:]
    /// OS から渡された「イベントを処理し終えたら呼べ」のハンドラ。
    private var pendingCompletion: (@Sendable () -> Void)?
    /// OS が「イベントは全部渡した」と言ったか（＋台帳更新の残り数が 0 で完了ハンドラを呼ぶ）。
    private var finishRequested = false
    private var settlesInFlight = 0
    /// 応答を受けて台帳へ書いている最中のジョブ。spool にはまだ在るが「未投入」ではない。
    /// ⚠️ これを除外しないと、次の flush が**済んだ直後の写真をもう一度上げる**
    /// （実機 diagnostics-74: 400 枚に対して 626 回投入・重複分は 409 → 前面経路送り）。
    private var settling: Set<String> = []
    /// この実行（1 つの処理枠）で投入済みのジョブ。同じ枠内では再投入しない
    /// （即失敗するジョブが 1 枠で 3 回試して諦めてしまうのを防ぐ＝再試行は枠ごとに 1 回）。
    private var attemptedThisRun: Set<String> = []
    /// 台帳を更新する相手の解決手段（アプリが起動時に結線。ストア構築を待てるよう async）。
    public var settlerProvider: (@Sendable () async -> Settler?)?

    public init(spool: UploadSpool = UploadSpool()) {
        self.spool = spool
        super.init()
    }

    /// 共有インスタンス。背景セッションは identifier ごとに 1 つ。
    public static let shared = BackgroundUploadSession()

    /// URLSession は**最初に要るときに**作る（作った瞬間に前回の応答が流れ込むので、
    /// `settlerProvider` を結線してから触ること）。
    private var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let _session { return _session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // 投入は BGTask（背景）で行うので、OS はどのみち裁量転送（電源＋Wi-Fi 時）として扱う。
        // 前面から投入した場合だけこの false が効く（急ぐ）。
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true  // 完了時にアプリを起こす
        config.allowsCellularAccess = false     // 回線ポリシー（既定 Wi-Fi のみ）に合わせる
        config.timeoutIntervalForResource = 24 * 60 * 60
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _session = s
        return s
    }

    // MARK: - 投入

    /// spool にあるジョブを背景セッションへ投入する（既に走っているタスクは重複投入しない）。
    /// - Returns: 投入した数。
    /// バックアップ 1 回の実行の始まり（同じ枠内の再投入抑止をリセットする）。
    public func beginRun() {
        lock.lock(); attemptedThisRun = []; lock.unlock()
    }

    @discardableResult
    public func enqueuePending(token: String) async -> Int {
        let running = await runningJobIDs()
        let split = Self.split(pending: spool.pendingJobs(), running: running, excluded: excludedFromEnqueue())
        for job in split.giveUp {
            BackupLogger.error("BackgroundUpload: giving up \(job.filename) after \(job.attempts) attempts")
            Diagnostics.mark("backup(bg): \(job.filename) を \(job.attempts) 回で諦めました（次回の通常対象へ）")
            spool.remove(id: job.id)
        }
        var count = 0
        for var job in split.enqueue {
            guard let arg = DropboxBackupUploader.uploadAPIArg(path: job.dropboxPath, autorename: false,
                                                               clientModified: job.creationDate)
            else { spool.remove(id: job.id); continue }
            var request = DropboxBackupUploader.uploadRequestWithoutBody(argStr: arg, token: token)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = session.uploadTask(with: request, fromFile: spool.bodyURL(for: job.id))
            task.taskDescription = job.id
            job.attempts += 1
            spool.update(job: job)
            noteAttempted(job.id)
            task.resume()
            count += 1
        }
        return count
    }

    /// （同期ヘルパ: async 文脈で NSLock を直接握らない）
    private func excludedFromEnqueue() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return settling.union(attemptedThisRun)
    }
    private func noteAttempted(_ id: String) {
        lock.lock(); attemptedThisRun.insert(id); lock.unlock()
    }

    /// spool のジョブを「投入する / 諦める」に分ける純ロジック。
    /// 転送中（OS が持っている）・台帳へ書いている最中・この枠で投入済み・409 待ち（前面経路の仕事）は触らない。
    static func split(pending: [UploadSpool.Job], running: Set<String>, excluded: Set<String> = [])
        -> (enqueue: [UploadSpool.Job], giveUp: [UploadSpool.Job]) {
        var enqueue: [UploadSpool.Job] = [], giveUp: [UploadSpool.Job] = []
        for job in pending where !running.contains(job.id) && !excluded.contains(job.id) && !job.conflict {
            if job.attempts >= maxAttempts { giveUp.append(job) } else { enqueue.append(job) }
        }
        return (enqueue, giveUp)
    }

    /// 応答 1 件をどう扱うかの純ロジック（delegate はこれを適用するだけ）。
    enum ResponseOutcome: Equatable {
        /// hash 一致＝台帳へ（済み）。
        case settle(savedPath: String, contentHash: String)
        /// spool に残して次の窓で再投入（通信エラー・hash 不一致・5xx・401 など）。
        case retry(reason: String)
        /// 409＝前面経路（hash 照合・autorename）へ。
        case conflict
    }

    static func classify(job: UploadSpool.Job, status: Int, body: Data, failed: Bool) -> ResponseOutcome {
        if failed { return .retry(reason: "transport error") }
        switch status {
        case 200:
            struct Resp: Decodable { let content_hash: String?; let path_lower: String? }
            let parsed = try? JSONDecoder().decode(Resp.self, from: body)
            guard let hash = parsed?.content_hash, hash == job.expectedHash else {
                // ⚠️ 200 でも hash 不一致は「済み」にしない（ADR-40）。
                return .retry(reason: "hash mismatch")
            }
            return .settle(savedPath: parsed?.path_lower ?? job.dropboxPath.lowercased(), contentHash: hash)
        case 409:
            return .conflict
        default:
            return .retry(reason: "HTTP \(status)")
        }
    }

    /// いま OS が転送中のジョブ ID（重複投入の防止）。
    func runningJobIDs() async -> Set<String> {
        await withCheckedContinuation { cont in
            session.getAllTasks { tasks in
                cont.resume(returning: Set(tasks.compactMap(\.taskDescription)))
            }
        }
    }

    /// 転送中のタスク数（画面表示・診断用）。
    public func inFlightCount() async -> Int { await runningJobIDs().count }

    // MARK: - 起動時の再接続

    /// 通常起動でセッションを取り直す（アプリが眠っている間に終わった転送の応答を受ける）。
    /// ストア群の準備ができてから呼ぶ（`settlerProvider` が待てるなら早くてもよい）。
    public func connect() { _ = session }

    /// `handleEventsForBackgroundURLSession` から呼ぶ。溜まっていた応答を処理し、
    /// 台帳更新まで終えてから `completion` を呼ぶ。
    public func attach(completion: @escaping @Sendable () -> Void) {
        lock.lock(); pendingCompletion = completion; finishRequested = false; lock.unlock()
        _ = session   // 生成＝応答の配信が始まる
    }

    private func endSettle(_ jobID: String) {
        lock.lock(); settlesInFlight -= 1; settling.remove(jobID); lock.unlock()
        completeIfDrained()
    }

    /// 「OS のイベント配信が終わった」と「台帳更新が全部終わった」の両方が揃ったら完了を通知する。
    private func completeIfDrained() {
        lock.lock()
        guard finishRequested, settlesInFlight == 0, let completion = pendingCompletion else {
            lock.unlock(); return
        }
        pendingCompletion = nil
        finishRequested = false
        lock.unlock()
        // ⚠️ 必ずメインで呼ぶ（UIKit の要求）。呼ばないと OS が次からアプリを起こさなくなる。
        DispatchQueue.main.async { completion() }
    }
}

// MARK: - URLSessionDelegate

extension BackgroundUploadSession: URLSessionDataDelegate {

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); bodies[dataTask.taskIdentifier, default: Data()].append(data); lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        guard let jobID = task.taskDescription, let job = spool.job(id: jobID) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1

        switch Self.classify(job: job, status: status, body: body, failed: error != nil) {
        case .retry(let reason):
            // spool は残す（次の窓で再投入・attempts で上限）。
            BackupLogger.error("BackgroundUpload: \(job.filename) — \(reason)\(error.map { " (\($0.localizedDescription))" } ?? "") — will retry")
            if reason == "hash mismatch" {
                Diagnostics.mark("backup(bg): hash 不一致 — \(job.filename)（再投入します）")
            }
        case .conflict:
            // 同パスに既存。hash 照合と autorename は前面経路の仕事（`BackupRunner.uploadOne`）。
            // 印を付けて spool に残し、次の窓で前面経路に回す。
            BackupLogger.info("BackgroundUpload: \(job.filename) already exists (409) — handing to foreground path")
            var marked = job
            marked.conflict = true
            spool.update(job: marked)
        case .settle(let savedPath, let hash):
            lock.lock(); settlesInFlight += 1; settling.insert(jobID); lock.unlock()
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.endSettle(jobID) }
                let settler = await self.settlerProvider?()
                let ok = await settler?.settle(job: job, savedPath: savedPath, contentHash: hash) ?? false
                if ok {
                    self.spool.remove(id: jobID)
                } else {
                    // 台帳に書けなかった＝「済み」にしていない。spool を残せば次の窓で上げ直す
                    // （実体はあるので 409 → 前面経路の hash 照合で転送なしに済む）。
                    BackupLogger.error("BackgroundUpload: settle failed for \(job.filename) — will retry")
                }
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); finishRequested = true; lock.unlock()
        completeIfDrained()
    }
}

/// `BackupRunner` から見た背景セッション（テストは spool の中身だけを検証し、実セッションは作らない）。
protocol BackgroundUploadEnqueuing: AnyObject, Sendable {
    /// バックアップ 1 回の実行の始まり（同じ枠内の再投入抑止をリセットする）。
    func beginRun()
    /// spool のジョブを OS へ渡す。戻り値は投入した数。
    func enqueuePending(token: String) async -> Int
}

extension BackgroundUploadSession: BackgroundUploadEnqueuing {}
