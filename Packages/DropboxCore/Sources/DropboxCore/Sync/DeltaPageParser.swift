import Foundation

/// `list_folder` / `list_folder/continue` の 1 ページ分の解析結果。
struct DeltaPage {
    let added: [DropboxFileItem]      // 画像ファイルのみ
    let removed: [String]             // 削除されたパス
    let subfolderPaths: [String]      // 非再帰スキャン時のみ使用
    let cursor: String
    let hasMore: Bool
}

/// list_folder レスポンスを `DeltaPage` に解析する純ロジック。
/// 画像判定・撮影日時（time_taken ?? client_modified）・media_info からの座標抽出・
/// 削除/サブフォルダの振り分けを担う。`DropboxSyncEngine` から分離してテスト可能にする。
enum DeltaPageParser {

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp", "avif", "jfif"
    ]

    private static let dateFormatter = ISO8601DateFormatter()

    /// list_folder(/continue) のレスポンス JSON を解析する。
    static func parse(_ data: Data) throws -> DeltaPage {
        // media_info（撮影地・撮影日時）は DropboxMediaInfo（共有）でデコード。pending 時は metadata が nil。
        struct ListResponse: Decodable {
            struct Entry: Decodable {
                let tag: String?
                let name: String?
                let path_lower: String?
                let content_hash: String?
                let client_modified: String?
                let media_info: DropboxMediaInfo?
                enum CodingKeys: String, CodingKey {
                    case tag = ".tag"; case name; case path_lower; case content_hash
                    case client_modified; case media_info
                }
            }
            let entries: [Entry]
            let cursor: String
            let has_more: Bool
        }

        let page = try JSONDecoder().decode(ListResponse.self, from: data)

        let added = page.entries.compactMap { entry -> DropboxFileItem? in
            guard entry.tag == "file",
                  let filePath = entry.path_lower,
                  let name = entry.name else { return nil }
            let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { return nil }
            // 撮影日時は time_taken を優先し、無ければ client_modified。撮影地は media_info の location。
            let mediaMetadata = entry.media_info?.metadata
            let timeTaken = mediaMetadata?.time_taken.flatMap { dateFormatter.date(from: $0) }
            let modified = entry.client_modified.flatMap { dateFormatter.date(from: $0) }
            let location = mediaMetadata?.location
            return DropboxFileItem(
                path: filePath, name: name, contentHash: entry.content_hash,
                captureDate: timeTaken ?? modified,
                latitude: location?.latitude, longitude: location?.longitude)
        }

        let removed = page.entries.compactMap { entry -> String? in
            guard entry.tag == "deleted", let p = entry.path_lower else { return nil }
            return p
        }

        let subfolderPaths = page.entries.compactMap { entry -> String? in
            guard entry.tag == "folder", let p = entry.path_lower else { return nil }
            return p
        }

        return DeltaPage(
            added: added, removed: removed, subfolderPaths: subfolderPaths,
            cursor: page.cursor, hasMore: page.has_more)
    }
}
