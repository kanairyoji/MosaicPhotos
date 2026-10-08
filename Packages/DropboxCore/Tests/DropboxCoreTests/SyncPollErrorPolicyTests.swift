import Foundation
import Testing
@testable import DropboxCore

/// 差分ポーリングの失敗の分け方（ADR-256・実機ログ diagnostics-105）。
///
/// ⚠️ longpoll は 30 秒以上ぶら下がるので、プロセスが中断されれば**必ず**切れる。
/// 実機では 1 本のログに `ERROR: poll error — タイムアウト` が 37 回出ていて、
/// しかも**そのログの ERROR はこれ 1 種類だけ**だった——本物のエラーが埋もれているのか
/// 無いのかが読み手に分からない状態。さらに UI を失敗状態にしていた。
@Suite("差分ポーリングの失敗の分け方")
struct SyncPollErrorPolicyTests {

    @Test("中断でぶら下がりが切れた（タイムアウト）は想定どおり")
    func timeoutFromSuspensionIsExpected() {
        #expect(SyncPollErrorPolicy.classify(URLError(.timedOut)) == .expected,
                "実機で 37 回出ていたのがこれ。ERROR に残すと本物のエラーが埋もれる")
    }

    @Test("こちらが止めた（取り消し）は失敗ではない")
    func cancellationIsExpected() {
        #expect(SyncPollErrorPolicy.classify(CancellationError()) == .expected)
        #expect(SyncPollErrorPolicy.classify(URLError(.cancelled)) == .expected)
    }

    @Test("回線が無い・切れたは想定どおり（黙って再試行すればよい）")
    func networkConditionsAreExpected() {
        for code: URLError.Code in [.networkConnectionLost, .notConnectedToInternet,
                                    .dataNotAllowed, .internationalRoamingOff, .callIsActive] {
            #expect(SyncPollErrorPolicy.classify(URLError(code)) == .expected,
                    "\(code) を報せても利用者には何もできない")
        }
    }

    /// ⚠️ **逆向きを縛る**。これが無いと「全部 expected」にしても通ってしまい、
    /// 本物の失敗が今度こそ本当に見えなくなる（ADR-119 の「空でも通る assert を書かない」）。
    @Test("利用者が何かしないと直らないものは、報せる")
    func realFailuresStayReportable() {
        struct AuthExpired: Error {}
        #expect(SyncPollErrorPolicy.classify(AuthExpired()) == .reportable,
                "URL 層以外の失敗（認証・解析・権限）は報せる")
        // HTTP 層の失敗（DropboxAPIClient が投げる種類）も報せる。
        let http = NSError(domain: "DropboxAPI", code: 401,
                           userInfo: [NSLocalizedDescriptionKey: "unauthorized"])
        #expect(SyncPollErrorPolicy.classify(http) == .reportable)
        // ⚠️ URL 層でも「サーバが無い／名前が引けない」は設定の問題なので報せる。
        #expect(SyncPollErrorPolicy.classify(URLError(.cannotFindHost)) == .reportable)
        #expect(SyncPollErrorPolicy.classify(URLError(.badURL)) == .reportable)
    }
}
