import Foundation
import Testing
@testable import BackupKit

@Suite("BackupPlanning.pendingUploads")
struct PendingUploadsTests {

    @Test("アップロード済みを除外し未アップロードのみ返す")
    func excludesUploaded() {
        let result = BackupPlanning.pendingUploads(
            allIdentifiers: ["a", "b", "c"],
            alreadyUploaded: ["b"],
            limit: 0
        )
        #expect(result.pending == ["a", "c"])
        #expect(result.skipped == 1)
    }

    @Test("表示順を保持する")
    func preservesOrder() {
        let result = BackupPlanning.pendingUploads(
            allIdentifiers: ["x", "y", "z", "w"],
            alreadyUploaded: [],
            limit: 0
        )
        #expect(result.pending == ["x", "y", "z", "w"])
        #expect(result.skipped == 0)
    }

    @Test("limit>0 で上限を適用する（スキップ数は上限の影響を受けない）")
    func appliesLimit() {
        let result = BackupPlanning.pendingUploads(
            allIdentifiers: ["a", "b", "c", "d", "e"],
            alreadyUploaded: ["a"],
            limit: 2
        )
        #expect(result.pending == ["b", "c"])  // 未アップロード [b,c,d,e] の先頭2件
        #expect(result.skipped == 1)            // a のみスキップ
    }

    @Test("limit<=0 は無制限")
    func zeroLimitMeansUnlimited() {
        let ids = (0..<100).map { "id\($0)" }
        let result = BackupPlanning.pendingUploads(allIdentifiers: ids, alreadyUploaded: [], limit: 0)
        #expect(result.pending.count == 100)
    }

    @Test("全件アップロード済みなら pending は空")
    func allUploaded() {
        let result = BackupPlanning.pendingUploads(
            allIdentifiers: ["a", "b"],
            alreadyUploaded: ["a", "b"],
            limit: 0
        )
        #expect(result.pending.isEmpty)
        #expect(result.skipped == 2)
    }
}

@Suite("BackupPlanning.dropboxErrorSummary")
struct DropboxErrorSummaryTests {

    @Test("error_summary フィールドを抽出する")
    func extractsErrorSummary() {
        let body = #"{"error_summary": "path/not_found/...", "error": {}}"#
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == "path/not_found/...")
    }

    @Test("JSON でなければ本文の先頭を返す")
    func fallsBackToBody() {
        let body = "Internal Server Error"
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == "Internal Server Error")
    }

    @Test("error_summary が無い JSON は本文先頭を返す")
    func missingFieldFallsBack() {
        let body = #"{"other": "value"}"#
        #expect(BackupPlanning.dropboxErrorSummary(from: body) == body)
    }

    @Test("長い本文は先頭300文字に切り詰める")
    func truncatesLongBody() {
        let body = String(repeating: "x", count: 500)
        #expect(BackupPlanning.dropboxErrorSummary(from: body).count == 300)
    }
}
