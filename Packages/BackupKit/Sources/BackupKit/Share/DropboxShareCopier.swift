import DropboxCore
import Foundation

/// 共有セットの Dropbox 操作（フォルダ作成・サーバーサイド一括コピー・一括削除・一覧）。
/// `DropboxBackupUploader` と同じ流儀で HTTP のみに依存し、認証（token）・SwiftData・
/// 状態管理から独立させてテスト可能にする。コピー/削除はサーバーサイドなので
/// 実体の転送は発生しない（機内モード・従量回線でも軽い）。
struct DropboxShareCopier {
    let httpClient: HTTPClient

    private static let createFolderURL = "https://api.dropboxapi.com/2/files/create_folder_v2"
    private static let copyBatchURL = "https://api.dropboxapi.com/2/files/copy_batch_v2"
    private static let copyBatchCheckURL = "https://api.dropboxapi.com/2/files/copy_batch/check_v2"
    private static let moveURL = "https://api.dropboxapi.com/2/files/move_v2"
    private static let deleteBatchURL = "https://api.dropboxapi.com/2/files/delete_batch"
    private static let deleteBatchCheckURL = "https://api.dropboxapi.com/2/files/delete_batch/check"
    private static let listFolderURL = "https://api.dropboxapi.com/2/files/list_folder"
    private static let listFolderContinueURL = "https://api.dropboxapi.com/2/files/list_folder/continue"

    /// 非同期ジョブのポーリング設定。通常は数秒で完了するが、アカウント負荷が高いと
    /// 100 件バッチが 1 分を超えることがある（diagnostics-52）。タイムアウト＝失敗扱いは
    /// 「ジョブはサーバー側で走り続ける」ため再コピー重複の温床になる——上限は長めに取る。
    var pollIntervalNs: UInt64 = 500_000_000
    var maxPollAttempts = 480   // 0.5s × 480 = 4 分

    // MARK: - 結果型

    struct CopyResult: Equatable {
        /// コピー元パス順の結果（成功 = 実パスとハッシュ / 失敗 = nil）。
        struct Entry: Equatable {
            let pathLower: String
            let contentHash: String?
        }
        let entries: [Entry?]
    }

    struct ListedFile: Equatable {
        let pathLower: String
        let name: String
        let rev: String?
        let contentHash: String?
        let isFolder: Bool
    }

    // MARK: - フォルダの移動（改名）

    enum MoveOutcome: Equatable {
        /// 移動できた。
        case moved
        /// 移動元が無い（まだ 1 度も反映していない等）＝記録だけ直せばよい。
        case sourceMissing
        /// **移動先が既にある**（`to/conflict/folder`）。移動では解決しないので、
        /// 呼び出し側が「移動先を正とする」判断をする（リトライしても永久に同じ）。
        case destinationExists
        /// 通信断・権限など。次回に持ち越す。
        case failed
    }

    /// フォルダを改名する（サーバーサイド move。実体の転送は起きない）。
    /// `autorename` は使わない——連番フォルダができると「どちらが正か」が分からなくなる。
    func moveFolder(from: String, to: String, token: String) async -> MoveOutcome {
        struct Body: Encodable {
            let from_path: String
            let to_path: String
            let autorename = false
        }
        var req = Self.rpcRequest(url: Self.moveURL, token: token)
        guard let body = try? JSONEncoder().encode(Body(from_path: from, to_path: to))
        else { return .failed }
        req.httpBody = body
        guard let (data, resp) = try? await httpClient.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return .failed }
        if status == 200 { return .moved }
        let text = String(data: data, encoding: .utf8) ?? ""
        if status == 409, text.contains("from_lookup/not_found") { return .sourceMissing }
        // ⚠️ 「移動先が既にある」は**リトライで解決しない**（実機 diagnostics-64〜66 で 409 が
        // 反映のたびに出続け、共有の移行が収束しなかった）。失敗と区別して呼び出し側へ返す。
        if status == 409, text.contains("to/conflict") { return .destinationExists }
        // ⚠️ エラータグまで残す。status だけだと「移動先が既にある」のか「通信/権限」なのかが
        // 実機ログから区別できず、毎回の反映で同じ失敗を繰り返しているのに手が出せない
        // （diagnostics-64/65 で 409 が続いた）。本文は Dropbox のエラー JSON（機密は含まない）。
        BackupLogger.error("ShareCopier: move failed (\(status)) — \(from) → \(to) — \(Self.errorSummary(text))")
        return .failed
    }

    /// Dropbox のエラー本文から要点だけを取り出す（長い JSON をログに流し込まない）。
    static func errorSummary(_ text: String, limit: Int = 200) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
    }

    // MARK: - フォルダ作成

    /// フォルダを作成する。既存（conflict）は成功扱い。
    func createFolder(path: String, token: String) async -> Bool {
        struct Body: Encodable { let path: String; let autorename = false }
        var req = Self.rpcRequest(url: Self.createFolderURL, token: token)
        guard let body = try? JSONEncoder().encode(Body(path: path)) else { return false }
        req.httpBody = body
        guard let (data, resp) = try? await httpClient.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return false }
        if status == 200 { return true }
        // 409 conflict/folder = 既に存在 → 成功扱い。
        if status == 409, String(data: data, encoding: .utf8)?.contains("conflict") == true {
            return true
        }
        BackupLogger.error("ShareCopier: create_folder failed (\(status)) — \(path)")
        return false
    }

    // MARK: - 一括コピー（サーバーサイド）

    /// (from, to) のペアを一括コピーする。**autorename は使わない**（diagnostics-52:
    /// タイムアウト→再コピーで "IMG (1).jpg" が量産された。宛先名は計画側が決定し、
    /// 衝突＝失敗エントリとして返す→次回の反映が実在一覧から**採用**して収束する）。
    /// 結果は入力順に対応する（失敗エントリは nil）。リクエスト自体の失敗は nil。
    func copyBatch(entries: [(from: String, to: String)], token: String) async -> CopyResult? {
        guard !entries.isEmpty else { return CopyResult(entries: []) }
        struct RelocationPath: Encodable {
            let from_path: String
            let to_path: String
        }
        struct Body: Encodable {
            let entries: [RelocationPath]
            let autorename = false
        }
        var req = Self.rpcRequest(url: Self.copyBatchURL, token: token)
        guard let body = try? JSONEncoder().encode(
            Body(entries: entries.map { RelocationPath(from_path: $0.from, to_path: $0.to) }))
        else { return nil }
        req.httpBody = body
        guard let data = await sendWithRetry(req, label: "copy_batch (\(entries.count) entries)") else {
            return nil
        }
        guard let result = await resolveBatchResult(initial: data, checkURL: Self.copyBatchCheckURL,
                                                    expectedCount: entries.count, token: token)
        else { return nil }
        return Self.copyResult(from: result)
    }

    // MARK: - 一括削除

    /// `delete_batch` の 1 リクエスト上限（API 仕様は 1,000。余裕を見て 500 で切る）。
    /// 暴走時の重複掃除では数百〜数千件を渡し得るので、必ずチャンクへ分ける（diagnostics-53）。
    private static let deleteChunkSize = 500

    /// パス群を一括削除する。全体の成否のみ返す（存在しないパスの失敗は許容する用途）。
    /// 上限を超える件数はチャンクに分けて順に実行する。
    func deleteBatch(paths: [String], token: String) async -> Bool {
        guard !paths.isEmpty else { return true }
        guard paths.count <= Self.deleteChunkSize else {
            var allOK = true
            for chunk in stride(from: 0, to: paths.count, by: Self.deleteChunkSize).map({
                Array(paths[$0..<min($0 + Self.deleteChunkSize, paths.count)])
            }) {
                if await !deleteBatch(paths: chunk, token: token) { allOK = false }
            }
            return allOK
        }
        struct DeleteArg: Encodable { let path: String }
        struct Body: Encodable { let entries: [DeleteArg] }
        var req = Self.rpcRequest(url: Self.deleteBatchURL, token: token)
        guard let body = try? JSONEncoder().encode(Body(entries: paths.map(DeleteArg.init)))
        else { return false }
        req.httpBody = body
        guard let data = await sendWithRetry(req, label: "delete_batch (\(paths.count) paths)") else {
            return false
        }
        guard let entries = await resolveBatchResult(initial: data,
                                                     checkURL: Self.deleteBatchCheckURL,
                                                     expectedCount: paths.count, token: token)
        else { return false }
        // ⚠️ **エントリ単位の失敗を必ず見る**。バッチ自体が完了しても、no_permission や
        // path_write で個別に失敗し得る。全体成否だけ見ていたため「削除できていないのに
        // 成功」となり、呼び出し側が記録を消してクラウドに管理不能なフォルダを残していた
        // （レビュー指摘）。「元から無い」だけは目的達成として成功に数える。
        let failed = entries.filter { !$0.isSuccess && !$0.isNotFound }
        guard failed.isEmpty else {
            BackupLogger.error("ShareCopier: delete_batch — \(failed.count)/\(entries.count) "
                + "entries failed (\(failed.compactMap { $0.failure?.tag }.joined(separator: ",")))")
            return false
        }
        return true
    }

    // MARK: - 一覧

    /// フォルダの一覧（ページング追従）。取得失敗は nil（「空」と区別する）。
    /// - Parameter recursive: true なら配下を丸ごと（ADR-183: 共有ルート 1 回でセット全部の実在が分かる）。
    func listFolder(path: String, token: String, recursive: Bool = false) async -> [ListedFile]? {
        struct Body: Encodable { let path: String; let recursive: Bool }
        struct ContinueBody: Encodable { let cursor: String }
        struct RawEntry: Decodable {
            let tag: String
            let name: String
            let path_lower: String?
            let rev: String?
            let content_hash: String?
            enum CodingKeys: String, CodingKey {
                case tag = ".tag", name, path_lower, rev, content_hash
            }
        }
        struct Page: Decodable {
            let entries: [RawEntry]
            let cursor: String
            let has_more: Bool
        }

        var out: [ListedFile] = []
        var req = Self.rpcRequest(url: Self.listFolderURL, token: token)
        guard let body = try? JSONEncoder().encode(Body(path: path, recursive: recursive)) else { return nil }
        req.httpBody = body

        for _ in 0..<200 {   // 200 ページ（1 ページ最大 2,000 件）＝再帰でも十分な上限
            guard let (data, resp) = try? await httpClient.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
            for e in page.entries {
                guard let pathLower = e.path_lower else { continue }
                out.append(ListedFile(pathLower: pathLower, name: e.name, rev: e.rev,
                                      contentHash: e.content_hash, isFolder: e.tag == "folder"))
            }
            guard page.has_more else { return out }
            req = Self.rpcRequest(url: Self.listFolderContinueURL, token: token)
            guard let contBody = try? JSONEncoder().encode(ContinueBody(cursor: page.cursor))
            else { return nil }
            req.httpBody = contBody
        }
        return out
    }

    // MARK: - サイドカーのアップロード（上書き）

    private static let uploadURL = "https://content.dropboxapi.com/2/files/upload"

    /// 小さなファイル（サイドカー JSON）を上書きアップロードする。
    func uploadFile(data: Data, to path: String, token: String) async -> Bool {
        struct Arg: Encodable {
            let path: String
            let mode = "overwrite"
            let mute = true
        }
        guard let argStr = encodeDropboxAPIArg(Arg(path: path)) else { return false }
        var req = URLRequest(url: URL(string: Self.uploadURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(argStr, forHTTPHeaderField: "Dropbox-API-Arg")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 60
        guard let (_, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            BackupLogger.error("ShareCopier: sidecar upload failed — \(path)")
            return false
        }
        return true
    }

    /// パスのファイルをダウンロードする（受信側のサイドカー読み込み用）。存在しない・エラーは nil。
    private static let downloadURL = "https://content.dropboxapi.com/2/files/download"
    func downloadFile(path: String, token: String) async -> Data? {
        struct Arg: Encodable { let path: String }
        guard let argStr = encodeDropboxAPIArg(Arg(path: path)) else { return nil }
        var req = URLRequest(url: URL(string: Self.downloadURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(argStr, forHTTPHeaderField: "Dropbox-API-Arg")
        req.timeoutInterval = 60
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - バッチ結果の解決（同期完了 or async job ポーリング）

    private struct BatchLaunch: Decodable {
        let tag: String
        let async_job_id: String?
        let entries: [BatchEntry]?
        enum CodingKeys: String, CodingKey { case tag = ".tag", async_job_id, entries }
    }
    private struct BatchEntry: Decodable {
        let tag: String
        let success: SuccessMeta?
        let failure: FailureInfo?
        enum CodingKeys: String, CodingKey { case tag = ".tag", success, failure }

        var isSuccess: Bool { tag == "success" }

        /// 「元から無い」失敗か。削除では成功と同じ意味になる（消したい物が無い＝目的達成）。
        /// Dropbox の DeleteError は `{".tag":"path_lookup","path_lookup":{".tag":"not_found"}}`
        /// の入れ子。表記ゆれに耐えるよう、どちらの階層でも not_found を拾う。
        var isNotFound: Bool {
            (failure?.tag ?? "").contains("not_found")
                || (failure?.path_lookup?.tag ?? "").contains("not_found")
        }

        struct FailureInfo: Decodable {
            let tag: String
            let path_lookup: Nested?
            enum CodingKeys: String, CodingKey { case tag = ".tag", path_lookup }
            struct Nested: Decodable {
                let tag: String
                enum CodingKeys: String, CodingKey { case tag = ".tag" }
            }
        }

        struct SuccessMeta: Decodable {
            let path_lower: String?
            let content_hash: String?
            /// delete_batch の success は {metadata: {...}} 形なので両対応。
            let metadata: Inner?
            struct Inner: Decodable { let path_lower: String?; let content_hash: String? }
        }
    }

    private func resolveBatchResult(initial: Data, checkURL: String,
                                    expectedCount: Int, token: String) async -> [BatchEntry]? {
        guard var launch = try? JSONDecoder().decode(BatchLaunch.self, from: initial) else {
            return nil
        }
        var attempts = 0
        // check 応答は async_job_id を含まないため、初回応答の ID を持ち回る。
        var knownJobID: String?
        while launch.tag == "async_job_id" || launch.tag == "in_progress" {
            guard let jobID = launch.async_job_id ?? knownJobID, attempts < maxPollAttempts else {
                BackupLogger.error("ShareCopier: batch job polling timed out")
                return nil
            }
            knownJobID = jobID
            attempts += 1
            // 削除などの変更操作が待っているときは、ここで速やかに降りる（ADR-112 追記6）。
            if Task.isCancelled {
                BackupLogger.info("ShareCopier: batch job polling cancelled")
                return nil
            }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            struct CheckBody: Encodable { let async_job_id: String }
            var req = Self.rpcRequest(url: checkURL, token: token)
            guard let body = try? JSONEncoder().encode(CheckBody(async_job_id: jobID))
            else { return nil }
            req.httpBody = body
            guard let data = await sendWithRetry(req, label: "batch check"),
                  let next = try? JSONDecoder().decode(BatchLaunch.self, from: data)
            else { return nil }
            launch = next
        }
        guard launch.tag == "complete", let entries = launch.entries,
              entries.count == expectedCount else {
            if launch.tag != "complete" {
                BackupLogger.error("ShareCopier: batch failed — \(launch.tag)")
            }
            return nil
        }
        return entries
    }

    /// バッチ結果 → コピー結果（失敗エントリは nil）。
    private static func copyResult(from entries: [BatchEntry]) -> CopyResult {
        CopyResult(entries: entries.map { entry in
            guard entry.isSuccess, let meta = entry.success else { return nil }
            let pathLower = meta.path_lower ?? meta.metadata?.path_lower
            let hash = meta.content_hash ?? meta.metadata?.content_hash
            guard let pathLower else { return nil }
            return CopyResult.Entry(pathLower: pathLower, contentHash: hash)
        })
    }

    // MARK: - 共通

    /// レート制限（429）と一時障害（5xx）だけを、`Retry-After` を尊重して再試行する。
    /// diagnostics-54: プロセス中断からの復帰直後に copy_batch が 32 回連続で失敗し、
    /// **ステータスコードをログに残していなかったため原因を特定できなかった**。
    /// 失敗時は必ず status とレスポンス本文の先頭を残す。
    private func sendWithRetry(_ req: URLRequest, label: String,
                               maxAttempts: Int = 4) async -> Data? {
        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            guard let (data, resp) = try? await httpClient.data(for: req),
                  let http = resp as? HTTPURLResponse else {
                BackupLogger.error("ShareCopier: \(label) transport error (attempt \(attempt))")
                return nil
            }
            if http.statusCode == 200 { return data }

            let retryable = http.statusCode == 429 || (500...599).contains(http.statusCode)
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            guard retryable, attempt < maxAttempts else {
                BackupLogger.error("ShareCopier: \(label) failed — HTTP \(http.statusCode) \(body)")
                return nil
            }
            // Retry-After（秒）を尊重。無ければ指数バックオフ（2/4/8 秒）。
            let hinted = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
            let delay = hinted ?? pow(2.0, Double(attempt))
            BackupLogger.info("ShareCopier: \(label) HTTP \(http.statusCode) — retrying in \(Int(delay))s (attempt \(attempt)/\(maxAttempts))")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return nil
    }

    private static func rpcRequest(url: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        return req
    }
}
