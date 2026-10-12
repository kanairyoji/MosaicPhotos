import Foundation

/// バックアップの純粋ロジック（Photos / ネットワーク非依存）。View / Engine から分離して
/// 単体テスト可能にする。
enum BackupPlanning {

    // 何を上げるか（差分・上限・共有の優先）は `BackupScopePolicy.uploadTargets`（ADR-275）。

    /// Dropbox のエラーレスポンス JSON から `error_summary` を抽出する。
    /// JSON でない / フィールドが無い場合は本文の先頭 300 文字を返す。
    static func dropboxErrorSummary(from body: String) -> String {
        struct Resp: Decodable { let error_summary: String? }
        if let data = body.data(using: .utf8),
           let r = try? JSONDecoder().decode(Resp.self, from: data),
           let s = r.error_summary {
            return s
        }
        return String(body.prefix(300))
    }
}
