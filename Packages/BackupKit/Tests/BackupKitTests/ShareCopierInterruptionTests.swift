import DropboxCore
import Foundation
import MosaicSupport
import Testing
@testable import BackupKit

/// 停止を跨いで切れた要求は ERROR にしない（diagnostics-110・ADR-256）。
///
/// 実機ログの ERROR 6 件は、どれも直前に `PROCESS SUSPENDED` があり、その後すべて回復していた。
/// ⚠️ 両方の向きを縛る——「全部 info にする」でも通る形にしない（本物の失敗は ERROR のまま）。
@Suite("共有のコピー: 停止を跨いで切れた要求は想定どおり")
struct ShareCopierInterruptionTests {

    /// 毎回同じエラーで落ちる HTTP。
    private struct FailingClient: HTTPClient {
        let error: Error
        func data(for request: URLRequest) async throws -> (Data, URLResponse) { throw error }
    }

    private static let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    /// 想定どおりではない通信の失敗（`SyncPollErrorPolicy` が `.reportable` と読むもの）。
    private static let badServerResponse = NSError(domain: NSURLErrorDomain,
                                                   code: NSURLErrorBadServerResponse)

    @Test("アップロード: timeout は info、それ以外は ERROR")
    func uploadSeverity() async {
        let tap = DiagnosticsLog.shared.tap()
        let id = UUID().uuidString
        let quiet = DropboxShareCopier(httpClient: FailingClient(error: Self.timedOut))
        #expect(await quiet.uploadFile(data: Data([1]), to: "/q-\(id).json", token: "t") == false)
        let loud = DropboxShareCopier(httpClient: FailingClient(error: Self.badServerResponse))
        #expect(await loud.uploadFile(data: Data([1]), to: "/l-\(id).json", token: "t") == false)
        try? await Task.sleep(for: .milliseconds(50))

        let lines = await tap.lines()
        let quietLines = lines.filter { $0.contains("/q-\(id).json") }
        let loudLines = lines.filter { $0.contains("/l-\(id).json") }
        #expect(quietLines.contains { $0.contains("upload interrupted (expected)") },
                "切れた回の行が無い: \(quietLines)")
        #expect(!quietLines.contains { $0.contains("ERROR") }, "停止を跨いだ要求を ERROR にした: \(quietLines)")
        #expect(loudLines.contains { $0.contains("ERROR") && $0.contains("upload failed (transport)") },
                "本物の失敗が ERROR になっていない: \(loudLines)")
    }

    @Test("一覧: timeout は interrupted、それ以外は failed（どちらも nil を返す）")
    func listOutcome() async {
        let quiet = DropboxShareCopier(httpClient: FailingClient(error: Self.timedOut))
        #expect(await quiet.listFolderOutcome(path: "/a", token: "t") == .interrupted)
        #expect(await quiet.listFolder(path: "/a", token: "t") == nil, "「取れない」を空と取り違えた")
        let loud = DropboxShareCopier(httpClient: FailingClient(error: Self.badServerResponse))
        #expect(await loud.listFolderOutcome(path: "/a", token: "t") == .failed)
    }

    @Test("解析の発見: 停止を跨いでルートが一覧できない回は ERROR にしない")
    func backupRootListingSeverity() async {
        let tap = DiagnosticsLog.shared.tap()
        let root = "/root-\(UUID().uuidString)"
        let quiet = ShareAnalysisFetch(httpClient: FailingClient(error: Self.timedOut))
        let result = await quiet.accountAnalysisRoots(backupRoot: root, ownDeviceFolder: "me", token: "t")
        #expect(result.listedAll == false, "取れなかったのに全部見たことにした")
        let loudRoot = root + "-loud"
        let loud = ShareAnalysisFetch(httpClient: FailingClient(error: Self.badServerResponse))
        _ = await loud.accountAnalysisRoots(backupRoot: loudRoot, ownDeviceFolder: "me", token: "t")
        try? await Task.sleep(for: .milliseconds(50))

        let lines = await tap.lines()
        let quietLines = lines.filter { $0.hasSuffix(root) }
        #expect(quietLines.contains { $0.contains("interrupted (expected)") }, "切れた回の行が無い: \(quietLines)")
        #expect(!quietLines.contains { $0.contains("ERROR") }, "停止を跨いだ一覧を ERROR にした: \(quietLines)")
        #expect(lines.contains { $0.hasSuffix(loudRoot) && $0.contains("ERROR") }, "本物の失敗が ERROR になっていない")
    }
}
