import Foundation

/// バックアップの純粋ロジック（Photos / ネットワーク非依存）。View / Engine から分離して
/// 単体テスト可能にする。
enum BackupPlanning {

    /// 未アップロードの localIdentifier を算出する。
    /// - Parameters:
    ///   - allIdentifiers: 全アセットの localIdentifier（表示順を保持）
    ///   - alreadyUploaded: アップロード済み ID 集合
    ///   - limit: 1 回でアップロードする上限（0 以下で無制限）
    /// - Returns: アップロード対象 `pending`（順序保持・上限適用後）と、スキップ済み件数 `skipped`
    static func pendingUploads(
        allIdentifiers: [String],
        alreadyUploaded: Set<String>,
        limit: Int
    ) -> (pending: [String], skipped: Int) {
        let notUploaded = allIdentifiers.filter { !alreadyUploaded.contains($0) }
        let skipped = allIdentifiers.count - notUploaded.count
        let pending = limit > 0 ? Array(notUploaded.prefix(limit)) : notUploaded
        return (pending, skipped)
    }

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
