import Foundation
import DropboxCore

/// **状態を持つ** Dropbox の偽サーバー（テスト専用）。
///
/// ## なぜ必要か
/// 従来のスタブは「決められた応答を順に返す」だけで、コピー・削除の結果が残らなかった。
/// しかし実機で起きた障害（重複約 1,300 件の生成・掃除の空回りループ）は、いずれも
/// **複数回の反映にまたがる**現象で、1 回の応答を検査するテストでは構造的に検出できない。
/// このサーバーはファイル表を保持し、`copy_batch` / `delete_batch` / `list_folder` を
/// 実際に反映するので、「反映を 2 回・3 回走らせたら収束するか」を検証できる。
///
/// ## 再現できる実障害
/// - `jobsTimeOutButComplete`: **クライアントにはタイムアウトを返すが、サーバー側では完了する**
///   非同期ジョブ（diagnostics-52 の暴走の引き金そのもの）。
/// - `rateLimitEveryNthRequest`: 429（diagnostics-54 で疑われたレート制限）。
/// - `failCopyPaths`: 特定のコピーだけ失敗させる（部分失敗の扱いを検証）。
actor FakeDropboxServer: HTTPClient {

    struct Entry: Equatable {
        var contentHash: String
        var isFolder: Bool
        var rev: String
    }

    /// path_lower → エントリ。
    private(set) var files: [String: Entry] = [:]
    /// 発行済みリクエストの記録（呼ばれ方の検証用）。
    private(set) var requestLog: [String] = []
    private var jobCounter = 0
    /// 完了待ちジョブ（check で返す結果）。
    private var pendingJobs: [String: String] = [:]
    private var requestCount = 0

    // MARK: - 障害注入

    /// 非同期ジョブを「クライアントには in_progress を返し続ける（＝タイムアウトさせる）」が、
    /// **サーバー側の効果は即座に適用**する。実機の暴走を正確に再現するための設定。
    var jobsTimeOutButComplete = false
    /// N 回に 1 回 429 を返す（0 で無効）。
    var rateLimitEveryNthRequest = 0
    /// この接頭辞に一致するコピー先は失敗させる。
    var failCopyPaths: Set<String> = []
    /// このパスの削除を失敗させる（no_permission 相当＝「無い」ではない本物の失敗）。
    var failDeletePaths: Set<String> = []
    /// move_v2 を通信エラー（500）にする。「通信断で改名できない回」を再現するため。
    var failMove = false

    init(files: [String: Entry] = [:]) { self.files = files }

    /// 既存ファイルを直接置く（テストの前提条件づくり）。
    func seed(_ path: String, hash: String, isFolder: Bool = false) {
        files[path.lowercased()] = Entry(contentHash: hash, isFolder: isFolder, rev: "r\(files.count)")
    }

    /// 外部（他端末・Dropbox の Web UI）からの削除を模す。
    func remove(_ path: String) { files.removeValue(forKey: path.lowercased()) }

    /// 現在のファイル一覧（フォルダを除く・パス昇順）。
    func filePaths() -> [String] {
        files.filter { !$0.value.isFolder }.keys.sorted()
    }

    /// アップロード（`files/upload`）の回数。「無駄に上げ直していないか」の検証用。
    /// ⚠️ 結果（ファイルの有無）だけを見ると、毎回上げ直す実装でも通ってしまう。
    func uploadCount() -> Int {
        requestLog.filter { $0.contains("files/upload") }.count
    }

    func setJobsTimeOutButComplete(_ value: Bool) { jobsTimeOutButComplete = value }
    func setRateLimit(everyNth: Int) { rateLimitEveryNthRequest = everyNth }
    func setFailCopyPaths(_ paths: Set<String>) { failCopyPaths = paths }
    func setFailDeletePaths(_ paths: Set<String>) { failDeletePaths = paths }
    func setFailMove(_ value: Bool) { failMove = value }

    // MARK: - HTTPClient

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        requestCount += 1
        requestLog.append(url)

        func resp(_ code: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code,
                                              httpVersion: nil, headerFields: nil)!)
        }
        if rateLimitEveryNthRequest > 0, requestCount % rateLimitEveryNthRequest == 0 {
            return resp(429, #"{"error_summary":"too_many_requests/"}"#)
        }

        let body = request.httpBody ?? Data()
        if url.contains("create_folder_v2") { return handleCreateFolder(body, resp) }
        if url.contains("copy_batch/check_v2") || url.contains("delete_batch/check") {
            return handleCheck(body, resp)
        }
        if url.contains("files/move_v2")  { return handleMove(body, resp) }
        if url.contains("copy_batch_v2") { return handleCopyBatch(body, resp) }
        if url.contains("delete_batch")  { return handleDeleteBatch(body, resp) }
        if url.contains("list_folder")   { return handleListFolder(body, resp) }
        if url.contains("get_metadata")  { return handleGetMetadata(body, resp) }
        if url.contains("files/upload")  { return handleUpload(request, resp) }
        if url.contains("files/download") { return handleDownload(request, resp) }
        return resp(400, #"{"error_summary":"unsupported_endpoint/"}"#)
    }

    // MARK: - エンドポイント

    private func handleCreateFolder(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        let key = parsed.path.lowercased()
        if files[key] != nil { return resp(409, #"{"error_summary":"path/conflict/folder/"}"#) }
        files[key] = Entry(contentHash: "", isFolder: true, rev: "d\(files.count)")
        return resp(200, "{}")
    }

    /// `files/move_v2`。フォルダ移動は配下ごと動く（本番と同じ）。
    private func handleMove(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let from_path: String; let to_path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        if failMove { return resp(500, "{}") }
        let from = parsed.from_path.lowercased()
        let to = parsed.to_path.lowercased()
        guard files[from] != nil else {
            return resp(409, #"{"error_summary":"from_lookup/not_found/"}"#)
        }
        guard files[to] == nil else {
            return resp(409, #"{"error_summary":"to/conflict/folder/"}"#)
        }
        for (path, entry) in files where path == from || path.hasPrefix(from + "/") {
            files.removeValue(forKey: path)
            files[to + String(path.dropFirst(from.count))] = entry
        }
        return resp(200, #"{"metadata":{"path_lower":"\#(to)"}}"#)
    }

    private func handleCopyBatch(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Path: Decodable { let from_path: String; let to_path: String }
        struct Body: Decodable { let entries: [Path]; let autorename: Bool }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }

        var results: [String] = []
        for entry in parsed.entries {
            let from = entry.from_path.lowercased()
            var to = entry.to_path.lowercased()
            guard let source = files[from], !source.isFolder else {
                results.append(#"{".tag":"failure","failure":{".tag":"relocation_error"}}"#)
                continue
            }
            if failCopyPaths.contains(to) {
                results.append(#"{".tag":"failure","failure":{".tag":"relocation_error"}}"#)
                continue
            }
            if files[to] != nil {
                guard parsed.autorename else {
                    // autorename 無効なら衝突は失敗（本番と同じ挙動）。
                    results.append(#"{".tag":"failure","failure":{".tag":"to/conflict/file/"}}"#)
                    continue
                }
                to = Self.autorenamed(to, existing: Set(files.keys))
            }
            files[to] = Entry(contentHash: source.contentHash, isFolder: false,
                              rev: "r\(files.count)")
            results.append(#"{".tag":"success","success":{".tag":"file","path_lower":"\#(to)","content_hash":"\#(source.contentHash)"}}"#)
        }
        return finishBatch(results: results, resp: resp)
    }

    private func handleDeleteBatch(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable { let path: String }
        struct Body: Decodable { let entries: [Arg] }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body) else {
            return resp(400, "{}")
        }
        var results: [String] = []
        for entry in parsed.entries {
            let key = entry.path.lowercased()
            if failDeletePaths.contains(key) {
                // 権限不足など「消せなかった」失敗。**not_found とは意味が違う**。
                results.append(#"{".tag":"failure","failure":{".tag":"path_write","path_write":{".tag":"no_write_permission"}}}"#)
                continue
            }
            if files[key] == nil {
                results.append(#"{".tag":"failure","failure":{".tag":"path_lookup","path_lookup":{".tag":"not_found"}}}"#)
                continue
            }
            // フォルダ削除は配下ごと消える（本番と同じ）。
            if files[key]?.isFolder == true {
                for path in files.keys where path == key || path.hasPrefix(key + "/") {
                    files.removeValue(forKey: path)
                }
            } else {
                files.removeValue(forKey: key)
            }
            results.append(#"{".tag":"success","success":{"metadata":{".tag":"file","path_lower":"\#(key)"}}}"#)
        }
        return finishBatch(results: results, resp: resp)
    }

    /// 非同期ジョブの表現。`jobsTimeOutButComplete` のときは**効果を適用済みのまま**
    /// クライアントには終わらない仕事として見せる（実障害の再現）。
    private func finishBatch(results: [String],
                             resp: (Int, String) -> (Data, URLResponse)) -> (Data, URLResponse) {
        let complete = #"{".tag":"complete","entries":[\#(results.joined(separator: ","))]}"#
        guard jobsTimeOutButComplete else { return resp(200, complete) }
        jobCounter += 1
        let jobID = "job\(jobCounter)"
        pendingJobs[jobID] = complete   // 効果は既に適用済み・クライアントには進行中を返し続ける
        return resp(200, #"{".tag":"async_job_id","async_job_id":"\#(jobID)"}"#)
    }

    private func handleCheck(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        // タイムアウト再現中は永遠に in_progress を返す。
        resp(200, #"{".tag":"in_progress"}"#)
    }

    private func handleListFolder(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String? }
        let root = ((try? JSONDecoder().decode(Body.self, from: body))?.path ?? "").lowercased()
        if !root.isEmpty, files[root] == nil {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        // 直下のみ（非再帰）。
        let entries = files.filter { path, _ in
            guard path != root, path.hasPrefix(root + "/") else { return false }
            return !path.dropFirst(root.count + 1).contains("/")
        }
        .sorted { $0.key < $1.key }
        .map { path, entry -> String in
            let name = (path as NSString).lastPathComponent
            let tag = entry.isFolder ? "folder" : "file"
            return #"{".tag":"\#(tag)","name":"\#(name)","path_lower":"\#(path)","rev":"\#(entry.rev)","content_hash":"\#(entry.contentHash)"}"#
        }
        return resp(200, #"{"entries":[\#(entries.joined(separator: ","))],"cursor":"c","has_more":false}"#)
    }

    private func handleGetMetadata(_ body: Data, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Body: Decodable { let path: String }
        guard let parsed = try? JSONDecoder().decode(Body.self, from: body),
              let entry = files[parsed.path.lowercased()] else {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        return resp(200, #"{"content_hash":"\#(entry.contentHash)","size":1}"#)
    }

    private func handleUpload(_ request: URLRequest, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable { let path: String }
        guard let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
              let arg = try? JSONDecoder().decode(Arg.self, from: Data(header.utf8)) else {
            return resp(400, "{}")
        }
        let key = arg.path.lowercased()
        let hash = "h\((request.httpBody ?? Data()).count)"
        files[key] = Entry(contentHash: hash, isFolder: false, rev: "r\(files.count)")
        return resp(200, #"{"path_lower":"\#(key)","content_hash":"\#(hash)"}"#)
    }

    private func handleDownload(_ request: URLRequest, _ resp: (Int, String) -> (Data, URLResponse))
        -> (Data, URLResponse) {
        struct Arg: Decodable { let path: String }
        guard let header = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
              let arg = try? JSONDecoder().decode(Arg.self, from: Data(header.utf8)),
              files[arg.path.lowercased()] != nil else {
            return resp(409, #"{"error_summary":"path/not_found/"}"#)
        }
        return resp(200, "{}")
    }

    /// Dropbox の autorename 相当（"a.jpg" → "a (1).jpg"）。
    private static func autorenamed(_ path: String, existing: Set<String>) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for n in 1...999 {
            let candidate = ext.isEmpty ? "\(dir)/\(stem) (\(n))" : "\(dir)/\(stem) (\(n)).\(ext)"
            if !existing.contains(candidate) { return candidate }
        }
        return path
    }
}

/// 常に同じトークンを返す（偽サーバーは検証しない）。
final class FakeTokenProvider: AccessTokenProvider, @unchecked Sendable {
    func freshAccessToken() async throws -> String { "test-token" }
}
