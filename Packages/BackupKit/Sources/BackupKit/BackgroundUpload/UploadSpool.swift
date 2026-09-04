import DropboxCore
import Foundation

/// 背景アップロードの**意図**（何を・どこへ・どの hash で）を永続化する台帳（ADR-181）。
///
/// ## なぜ要るか
/// `URLSession` の背景転送は、アプリが休眠・終了した後も OS が続け、**応答は後日**
/// （別プロセス起動で）届く。応答が届いたとき「これは何の写真だったか」を知る手段が
/// メモリには無いので、投入時に**ファイルへ**書いておく。
///
/// ## 不変条件
/// - 1 ジョブ = 1 ファイル（`<uuid>.json`）。原子的に書き、原子的に消す。
/// - **spool の本体（`<uuid>.bin`）と意図（`.json`）は対**。意図だけ・本体だけの孤児は
///   起動時の掃除で消す。
/// - 「済み」の判断（ADR-40 の hash 照合）は**応答が届いた側**で行う。投入側は判断しない。
public struct UploadSpool: Sendable {

    /// 1 ジョブぶんの意図。応答が届いたときに台帳へ書く材料をすべて持つ。
    public struct Job: Codable, Sendable {
        let id: String
        let localIdentifier: String
        let filename: String
        let dropboxPath: String
        /// 保存先ルート（`<root>/<端末>/Backup`）。メタデータの再送キューの名前空間に要る。
        let backupRoot: String
        /// 投入時にローカルで計算した content_hash（応答と照合する・ADR-40）。
        let expectedHash: String
        let byteCount: Int
        let creationDate: Date?
        /// メタデータ（人物名・アルバム・位置・お気に入り）。端末を消すと再生成できない情報なので
        /// 意図と一緒に持つ（ADR-171 のジャーナルと同じ理由）。
        let entry: DropboxBackupMetadata.Entry
        let enqueuedAt: Date
        /// 何回投入したか（失敗のたびに増える。上限で諦める＝永久に回し続けない）。
        var attempts: Int
        /// 背景で 409（同パスに既存）を受けた。hash 照合と autorename は**前面経路**の仕事なので、
        /// 次の窓では spool に入れず前面経路へ回す（`BackupRunner`）。
        var conflict: Bool = false

        /// 投入の意図を組む（前面経路 `uploadOne` と同じ材料・同じ保存先規則）。
        /// PHAsset を値に分解して受けるのは、macOS のテストから同じ規則を検証するため。
        static func make(localIdentifier: String, filename: String, data: Data,
                         backupRoot: String, creationDate: Date?, isFavorite: Bool,
                         latitude: Double?, longitude: Double?, isScreenshot: Bool,
                         people: [String], albums: [String], now: Date = Date()) -> Job {
            let hash = DropboxContentHash.hash(of: data)
            return Job(
                id: UUID().uuidString,
                localIdentifier: localIdentifier,
                filename: filename,
                dropboxPath: BackupLayout.photoFolder(backupRoot: backupRoot, captureDate: creationDate)
                    + "/" + filename,
                backupRoot: backupRoot,
                expectedHash: hash,
                byteCount: data.count,
                creationDate: creationDate,
                entry: DropboxBackupMetadata.Entry(
                    people: people, albums: albums, isFavorite: isFavorite,
                    date: creationDate.map { ISO8601DateFormatter().string(from: $0) },
                    contentHash: hash, localIdentifier: localIdentifier,
                    latitude: latitude, longitude: longitude, isScreenshot: isScreenshot),
                enqueuedAt: now,
                attempts: 0)
        }
    }

    let directory: URL

    /// 既定の置き場: Caches 配下。
    ///
    /// ⚠️ 本体（数 MB × 数百）は Caches でよい——消されても**端末の写真から作り直せる**
    /// （spool は写真のコピーにすぎない）。意図（`.json`）も同じ場所でよい: 消えたら
    /// その写真は「済み」が付かないまま次回の対象に戻るだけで、失うものは無い。
    public static func defaultDirectory() -> URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("BackupSpool", isDirectory: true)
    }

    public init(directory: URL = UploadSpool.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func bodyURL(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("bin") }
    func jobURL(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }

    /// 本体と意図を書く。**本体 → 意図の順**（意図があるのに本体が無い、を作らない）。
    /// - Returns: 書けたか。false なら投入してはいけない。
    @discardableResult
    func write(job: Job, body: Data) -> Bool {
        do {
            try body.write(to: bodyURL(for: job.id), options: .atomic)
            let json = try JSONEncoder().encode(job)
            try json.write(to: jobURL(for: job.id), options: .atomic)
            return true
        } catch {
            BackupLogger.error("UploadSpool: write failed — \(error)")
            remove(id: job.id)
            return false
        }
    }

    func job(id: String) -> Job? {
        guard let data = try? Data(contentsOf: jobURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(Job.self, from: data)
    }

    /// 意図を書き換える（試行回数の更新）。
    func update(job: Job) {
        guard let json = try? JSONEncoder().encode(job) else { return }
        try? json.write(to: jobURL(for: job.id), options: .atomic)
    }

    /// 本体と意図を消す（済み・諦め）。
    func remove(id: String) {
        try? FileManager.default.removeItem(at: bodyURL(for: id))
        try? FileManager.default.removeItem(at: jobURL(for: id))
    }

    /// 現在 spool にあるジョブ（意図があるもの）。孤児（本体が無い）は落とし、掃除する。
    func pendingJobs() -> [Job] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil)
        else { return [] }
        var jobs: [Job] = []
        for url in files where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            guard let job = job(id: id) else { try? FileManager.default.removeItem(at: url); continue }
            guard FileManager.default.fileExists(atPath: bodyURL(for: id).path) else {
                // 本体が無い意図＝投入できない。消して次回の対象へ戻す。
                try? FileManager.default.removeItem(at: url)
                continue
            }
            jobs.append(job)
        }
        // 意図の無い本体（書き込み途中で落ちた）も消す。
        for url in files where url.pathExtension == "bin" {
            let id = url.deletingPathExtension().lastPathComponent
            if !FileManager.default.fileExists(atPath: jobURL(for: id).path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return jobs.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    /// spool の総バイト数（投入量の上限判定用）。
    func totalBytes() -> Int {
        pendingJobs().reduce(0) { $0 + $1.byteCount }
    }

    /// spool のあるボリュームの空き容量（取れなければ nil＝上限判定は保守的に「足りない」扱い）。
    func freeBytes() -> Int? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
    }
}

/// spool に**どこまで積むか**の純ロジック（ADR-181）。
///
/// 上限は「OS が転送を終えるまで端末に置いておく写真のコピー」の量。積みすぎても速くは
/// ならず（回線は 1 本）、ディスクを食うだけなので、1 窓ぶんの転送量に見合う程度に留める。
/// 上限に達したら**その窓は終わり**——残りは次の窓（spool が捌けた分だけ空く）。
struct BackgroundUploadPolicy: Sendable {
    /// spool に置くジョブ数の上限。
    var maxJobs = 400
    /// spool の総バイト数の上限（1 GB ≒ HEIC 250〜300 枚）。
    var maxBytes = 1_000_000_000
    /// これを下回る空き容量では積まない（写真のコピーで端末を満杯にしない）。
    var minFreeBytes = 3_000_000_000

    /// 次の 1 枚を積めるか。空き容量が読めないときは積まない（保守的）。
    func canSpool(jobCount: Int, spooledBytes: Int, nextBytes: Int, freeBytes: Int?) -> Bool {
        guard jobCount < maxJobs else { return false }
        guard spooledBytes + nextBytes <= maxBytes else { return false }
        guard let freeBytes, freeBytes - nextBytes >= minFreeBytes else { return false }
        return true
    }
}
