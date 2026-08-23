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
    private static let deleteBatchURL = "https://api.dropboxapi.com/2/files/delete_batch"
    private static let deleteBatchCheckURL = "https://api.dropboxapi.com/2/files/delete_batch/check"
    private static let listFolderURL = "https://api.dropboxapi.com/2/files/list_folder"
    private static let listFolderContinueURL = "https://api.dropboxapi.com/2/files/list_folder/continue"

    /// 非同期ジョブのポーリング設定（サーバーサイドコピーは通常数秒で完了する）。
    var pollIntervalNs: UInt64 = 500_000_000
    var maxPollAttempts = 120

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

    /// (from, to) のペアを一括コピーする。autorename 有効（衝突時は Dropbox が改名し、
    /// 結果の実パスを返す）。結果は入力順に対応する（失敗エントリは nil）。
    /// リクエスト自体の失敗は nil。
    func copyBatch(entries: [(from: String, to: String)], token: String) async -> CopyResult? {
        guard !entries.isEmpty else { return CopyResult(entries: []) }
        struct RelocationPath: Encodable {
            let from_path: String
            let to_path: String
        }
        struct Body: Encodable {
            let entries: [RelocationPath]
            let autorename = true
        }
        var req = Self.rpcRequest(url: Self.copyBatchURL, token: token)
        guard let body = try? JSONEncoder().encode(
            Body(entries: entries.map { RelocationPath(from_path: $0.from, to_path: $0.to) }))
        else { return nil }
        req.httpBody = body
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            BackupLogger.error("ShareCopier: copy_batch request failed (\(entries.count) entries)")
            return nil
        }
        return await resolveBatchResult(initial: data, checkURL: Self.copyBatchCheckURL,
                                        expectedCount: entries.count, token: token)
    }

    // MARK: - 一括削除

    /// パス群を一括削除する。全体の成否のみ返す（存在しないパスの失敗は許容する用途）。
    func deleteBatch(paths: [String], token: String) async -> Bool {
        guard !paths.isEmpty else { return true }
        struct DeleteArg: Encodable { let path: String }
        struct Body: Encodable { let entries: [DeleteArg] }
        var req = Self.rpcRequest(url: Self.deleteBatchURL, token: token)
        guard let body = try? JSONEncoder().encode(Body(entries: paths.map(DeleteArg.init)))
        else { return false }
        req.httpBody = body
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            BackupLogger.error("ShareCopier: delete_batch request failed (\(paths.count) paths)")
            return false
        }
        let result = await resolveBatchResult(initial: data, checkURL: Self.deleteBatchCheckURL,
                                              expectedCount: paths.count, token: token)
        return result != nil
    }

    // MARK: - 一覧

    /// フォルダ直下の一覧（非再帰・ページング追従）。取得失敗は nil（「空」と区別する）。
    func listFolder(path: String, token: String) async -> [ListedFile]? {
        struct Body: Encodable { let path: String; let recursive = false }
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
        guard let body = try? JSONEncoder().encode(Body(path: path)) else { return nil }
        req.httpBody = body

        for _ in 0..<100 {   // 100 ページ（1 ページ最大 2,000 件）で十分な上限
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
        enum CodingKeys: String, CodingKey { case tag = ".tag", success }
        struct SuccessMeta: Decodable {
            let path_lower: String?
            let content_hash: String?
            /// delete_batch の success は {metadata: {...}} 形なので両対応。
            let metadata: Inner?
            struct Inner: Decodable { let path_lower: String?; let content_hash: String? }
        }
    }

    private func resolveBatchResult(initial: Data, checkURL: String,
                                    expectedCount: Int, token: String) async -> CopyResult? {
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
            try? await Task.sleep(nanoseconds: pollIntervalNs)
            struct CheckBody: Encodable { let async_job_id: String }
            var req = Self.rpcRequest(url: checkURL, token: token)
            guard let body = try? JSONEncoder().encode(CheckBody(async_job_id: jobID))
            else { return nil }
            req.httpBody = body
            guard let (data, resp) = try? await httpClient.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
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
        return CopyResult(entries: entries.map { entry in
            guard entry.tag == "success", let meta = entry.success else { return nil }
            let pathLower = meta.path_lower ?? meta.metadata?.path_lower
            let hash = meta.content_hash ?? meta.metadata?.content_hash
            guard let pathLower else { return nil }
            return CopyResult.Entry(pathLower: pathLower, contentHash: hash)
        })
    }

    // MARK: - 共通

    private static func rpcRequest(url: String, token: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        return req
    }
}
