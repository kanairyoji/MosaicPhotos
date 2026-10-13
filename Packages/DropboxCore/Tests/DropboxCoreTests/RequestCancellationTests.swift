import Foundation
import Testing
@testable import DropboxCore

/// 「こちらが止めた要求か」の判定（ADR-277・実機ログ diagnostics-108）。
///
/// ⚠️ この判定は以前 `SyncPollErrorPolicy` の中にだけあり、フル画像の取得は持っていなかった。
/// 写真を開いてすぐ閉じただけで `ERROR: fullImage() download failed — キャンセルしました` が残り、
/// ADR-256 で「想定どおりを ERROR に残さない」と決めたのに、**決めた場所以外では効いていなかった**。
/// 判定を 1 か所に出し、ポーリング側もそれを使う。
@Suite("こちらが止めた要求の判定")
struct RequestCancellationTests {

    @Test("Task の取り消しと URLSession の取り消しは「止めた」")
    func cancellationsMatch() {
        #expect(RequestCancellation.matches(CancellationError()))
        #expect(RequestCancellation.matches(URLError(.cancelled)))
    }

    /// ⚠️ 逆向きも縛る（ADR-256）: 全部を「止めた」にしても通る形にしない。
    /// フル画像の取得では、回線断・タイムアウト・認証切れは**利用者に見える失敗**なので残す。
    @Test("回線断・タイムアウト・HTTP エラーは「止めた」ではない")
    func failuresDoNotMatch() {
        #expect(!RequestCancellation.matches(URLError(.timedOut)))
        #expect(!RequestCancellation.matches(URLError(.notConnectedToInternet)))
        #expect(!RequestCancellation.matches(URLError(.userAuthenticationRequired)))
        #expect(!RequestCancellation.matches(DropboxAPIClient.APIError.http(status: 401, body: "")))
        #expect(!RequestCancellation.matches(NSError(domain: NSCocoaErrorDomain, code: NSURLErrorCancelled)),
                "別のドメインの同じ番号を取り消しと読んでいる")
    }

    @Test("ポーリングの分類も同じ判定を使う（止めたものは想定どおり）")
    func pollPolicyAgrees() {
        for error in [CancellationError() as Error, URLError(.cancelled)] {
            #expect(RequestCancellation.matches(error))
            #expect(SyncPollErrorPolicy.classify(error) == .expected)
        }
    }
}
