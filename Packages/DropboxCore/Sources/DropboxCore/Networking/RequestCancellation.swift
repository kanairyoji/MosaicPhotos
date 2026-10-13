import Foundation

/// **こちらが止めた要求か**（失敗ではない・ADR-256/277）。
///
/// `Task` の取り消し（画面を閉じた・前面復帰・窓の期限切れ）と、URLSession 側の取り消しの 2 つ。
/// どちらも利用者にも開発者にも**何もすることが無い**ので、記録は info にする
/// ——ERROR に残すと本物のエラーが埋もれる（実機ログ diagnostics-108: フル画像を開いてすぐ
/// 閉じただけで `ERROR: fullImage() download failed — キャンセルしました`）。
///
/// ⚠️ 判定はここ 1 か所（`SyncPollErrorPolicy` もこれを使う）。同じ判断を 2 か所に書くと
/// 片方だけ直る（CLAUDE.md・ADR-196 の一般形）。
public enum RequestCancellation {
    public static func matches(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
