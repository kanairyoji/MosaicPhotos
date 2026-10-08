import Foundation

/// **差分ポーリングの失敗を「想定どおり」と「報せるべき」に分ける**（純ロジック・ADR-256）。
///
/// ⚠️ なぜ要るか（実機ログ diagnostics-105）
/// longpoll は 30 秒以上ぶら下がる作りなので、**プロセスが中断されれば必ず切れる**。
/// 実機では `bgtask: begin` / `bgtask: end` の直後にこれが起き、
/// `ERROR: SyncEngine: poll error — リクエストがタイムアウトになりました。` が
/// **1 本のログに 37 回**出ていた。
///
/// 害は 2 つあった:
/// 1. `error` は Release でも診断ログに残る（CLAUDE.md）。想定どおりの事象が 37 行を占め、
///    **本物のエラーを埋める**——このログの ERROR は実際これ 1 種類だけで、
///    「エラーは出ていない」のか「埋もれている」のか読み手には区別できない。
/// 2. ⚠️ **UI を失敗状態にしていた**（`reportState(.error(...))`）。アプリに戻った利用者には
///    何も壊れていないのに同期が失敗したように見え得る。
///
/// 「中断で切れた」と「本当に繋がらない」を**型で分ける**。どちらも次の周回で再試行するので、
/// 違いは**記録と表示**だけ——だからこそ純ロジックに出してテストで固定する。
enum SyncPollErrorPolicy {

    enum Verdict: Equatable {
        /// 想定どおり（中断・回線の瞬断）。記録は info、UI は失敗にしない。
        case expected
        /// 本当に報せるべき。記録は error、UI も失敗にする。
        case reportable
    }

    /// ⚠️ **ここに並ぶのは「アプリの外の事情で、黙って再試行すればよいもの」だけ**。
    /// 認証切れ・権限・パスの不整合などは `reportable`（利用者が何かしないと直らない）。
    static func classify(_ error: Error) -> Verdict {
        // ⚠️ `Task` の取り消し（前面復帰・窓の期限切れ）。こちらが止めたのだから失敗ではない。
        if error is CancellationError { return .expected }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .reportable }
        switch ns.code {
        case NSURLErrorTimedOut,                 // longpoll がぶら下がったまま中断された
             NSURLErrorCancelled,                // URLSession 側の取り消し
             NSURLErrorNetworkConnectionLost,    // 圏外へ入る・Wi-Fi が切れる
             NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed,           // モバイルデータが許可されていない
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorSecureConnectionFailed:   // 公共 Wi-Fi の captive portal など
            return .expected
        default:
            return .reportable
        }
    }
}
