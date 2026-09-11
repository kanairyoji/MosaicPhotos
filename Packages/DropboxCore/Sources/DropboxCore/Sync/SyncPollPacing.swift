import Foundation

/// 差分同期のポーリング間隔（純ロジック・diagnostics-81）。
///
/// ## なぜ要るか
/// バックアップや家族共有のコピーは**アプリ自身が監視しているルート**へ落ちる。すると
/// `list_folder/longpoll` は `changes=true` を返し続け、続く `continue` が
/// 「表示対象の画像は 0 件」を返しても、ループは**待たずに次の longpoll** を投げていた。
/// 実機ログでは 10 分間に 202 周（1 周あたり約 0.7 秒・ログ行の 47%）回り続け、
///
/// - ネットワーク往復と SwiftData の書き込みが処理枠を食う（解析・バックアップと同じ資源）、
/// - Dropbox の API レートを消費して**自分のアップロードが 429 を受ける**、
/// - 診断ログ（末尾 256KB）を埋め尽くし、**夜間に何が起きたかの証拠が消える**、
///
/// という三重の実害が出ていた。`changes=false` 側には最小待ちがあったのに、
/// `changes=true` 側だけ素通りだったのが原因。
///
/// ## 規則
/// - 1 周ごとに**最低 `minDelayNs`** は空ける（ビジーループにしない）。
/// - 中身が空（表示対象の増減 0）の周が続いたら**指数的に待ちを延ばす**（上限 `maxDelayNs`）。
/// - **実際の変化が 1 件でもあれば即リセット**（本物の更新には従来どおり素早く追従する）。
enum SyncPollPacing {

    /// 1 周あたりの最小待ち。
    static let minDelayNs: UInt64 = 1_000_000_000          // 1 s
    /// 空振りが続いたときの上限。
    static let maxDelayNs: UInt64 = 30_000_000_000         // 30 s

    /// 次の longpoll までの待ち時間。
    /// - Parameter emptyStreak: 「変化を告げられたのに中身が空だった」周の連続数（0 で実変化あり）。
    static func delayNs(emptyStreak: Int) -> UInt64 {
        guard emptyStreak > 0 else { return minDelayNs }
        // 1s, 2s, 4s, 8s, 16s, 30s（上限）
        let shift = min(emptyStreak - 1, 16)
        let scaled = minDelayNs << UInt64(shift)
        return min(scaled, maxDelayNs)
    }
}
