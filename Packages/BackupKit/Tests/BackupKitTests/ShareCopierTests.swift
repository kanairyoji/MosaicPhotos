import Foundation
import Testing
@testable import BackupKit
import DropboxCore

/// リクエスト列に応答を順番に返すスタブ（copy_batch → check のポーリング列を再現する）。
private actor SequencedHTTPClient: HTTPClient {
    private var responses: [(status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(status: Int, body: String)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let next = responses.isEmpty ? (status: 500, body: "") : responses.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: next.status,
                                   httpVersion: nil, headerFields: nil)!
        return (Data(next.body.utf8), resp)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

@Suite("DropboxShareCopier")
struct DropboxShareCopierTests {

    private func makeCopier(_ stub: SequencedHTTPClient) -> DropboxShareCopier {
        var copier = DropboxShareCopier(httpClient: stub)
        copier.pollIntervalNs = 1_000_000   // テストは 1ms でポーリング
        return copier
    }

    // MARK: - createFolder

    @Test("フォルダ作成は 200 で成功・409 conflict は成功扱い")
    func createFolderTreatsConflictAsSuccess() async {
        let ok = SequencedHTTPClient([(200, "{}")])
        #expect(await makeCopier(ok).createFolder(path: "/s/x", token: "t"))

        let conflict = SequencedHTTPClient([
            (409, #"{"error_summary": "path/conflict/folder/..", "error": {}}"#)])
        #expect(await makeCopier(conflict).createFolder(path: "/s/x", token: "t"))

        let denied = SequencedHTTPClient([(401, "{}")])
        #expect(await makeCopier(denied).createFolder(path: "/s/x", token: "t") == false)
    }

    // MARK: - copyBatch

    @Test("同期完了（complete）: 成功エントリの実パスとハッシュを入力順に返す")
    func copyBatchSyncComplete() async {
        let body = """
        {".tag": "complete", "entries": [
            {".tag": "success", "success": {".tag": "file", "path_lower": "/s/t/a.jpg", "content_hash": "h1"}},
            {".tag": "failure", "failure": {".tag": "relocation_error"}}
        ]}
        """
        let stub = SequencedHTTPClient([(200, body)])
        let result = await makeCopier(stub).copyBatch(
            entries: [(from: "/b/a.jpg", to: "/s/t/a.jpg"), (from: "/b/b.jpg", to: "/s/t/b.jpg")],
            token: "t")
        #expect(result?.entries.count == 2)
        #expect(result?.entries[0] == .init(pathLower: "/s/t/a.jpg", contentHash: "h1"))
        #expect(result?.entries[1] == nil, "失敗エントリが nil にならない")
    }

    @Test("async job: check をポーリングして完了結果を返す")
    func copyBatchAsyncJobPolling() async {
        let launch = #"{".tag": "async_job_id", "async_job_id": "job1"}"#
        let inProgress = #"{".tag": "in_progress"}"#
        let complete = """
        {".tag": "complete", "entries": [
            {".tag": "success", "success": {".tag": "file", "path_lower": "/s/t/a.jpg", "content_hash": "h1"}}
        ]}
        """
        let stub = SequencedHTTPClient([(200, launch), (200, inProgress), (200, complete)])
        let result = await makeCopier(stub).copyBatch(
            entries: [(from: "/b/a.jpg", to: "/s/t/a.jpg")], token: "t")
        #expect(result?.entries.first??.pathLower == "/s/t/a.jpg")
        let requests = await stub.recordedRequests()
        #expect(requests.count == 3, "launch + check×2 のはず: \(requests.count)")
        // check には async_job_id が入る。
        let checkBody = String(data: requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(checkBody.contains("job1"))
    }

    @Test("リクエスト失敗（HTTP エラー）は nil＝計画側で failed 扱い")
    func copyBatchRequestFailure() async {
        let stub = SequencedHTTPClient([(500, "")])
        let result = await makeCopier(stub).copyBatch(
            entries: [(from: "/b/a.jpg", to: "/s/t/a.jpg")], token: "t")
        #expect(result == nil)
    }

    // MARK: - listFolder

    @Test("一覧はページングを追従し、フォルダとファイルを区別する")
    func listFolderPaging() async {
        let page1 = """
        {"entries": [
            {".tag": "folder", "name": "Trip", "path_lower": "/s/trip"},
            {".tag": "file", "name": "a.jpg", "path_lower": "/s/a.jpg", "rev": "r1", "content_hash": "h1"}
        ], "cursor": "c1", "has_more": true}
        """
        let page2 = """
        {"entries": [
            {".tag": "file", "name": "b.jpg", "path_lower": "/s/b.jpg", "rev": "r2", "content_hash": "h2"}
        ], "cursor": "c2", "has_more": false}
        """
        let stub = SequencedHTTPClient([(200, page1), (200, page2)])
        let listed = await makeCopier(stub).listFolder(path: "/s", token: "t")
        #expect(listed?.count == 3)
        #expect(listed?.filter(\.isFolder).map(\.pathLower) == ["/s/trip"])
        #expect(listed?.last?.rev == "r2")
    }

    @Test("一覧の取得失敗は nil（「空」と区別＝再コピー暴走を防ぐ）")
    func listFolderFailureIsNil() async {
        let stub = SequencedHTTPClient([(409, #"{"error_summary": "path/not_found/"}"#)])
        let listed = await makeCopier(stub).listFolder(path: "/s/none", token: "t")
        #expect(listed == nil)
    }

    // MARK: - deleteBatch

    @Test("削除も async job を追従して成否を返す")
    func deleteBatchPolling() async {
        let launch = #"{".tag": "async_job_id", "async_job_id": "d1"}"#
        let complete = """
        {".tag": "complete", "entries": [
            {".tag": "success", "success": {"metadata": {".tag": "file", "path_lower": "/s/a.jpg"}}}
        ]}
        """
        let stub = SequencedHTTPClient([(200, launch), (200, complete)])
        #expect(await makeCopier(stub).deleteBatch(paths: ["/s/a.jpg"], token: "t"))
    }
}
