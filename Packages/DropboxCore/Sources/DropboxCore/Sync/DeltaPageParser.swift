import Foundation

/// `list_folder` / `list_folder/continue` の 1 ページ分の解析結果。
struct DeltaPage {
    /// 画像と動画（動画は `video` が付く・ADR-282）。キャッシュは種類ごとに別の表へ振り分ける。
    let added: [DropboxFileItem]
    let removed: [String]             // 削除されたパス
    let subfolderPaths: [String]      // 非再帰スキャン時のみ使用
    let cursor: String
    let hasMore: Bool
}

/// list_folder レスポンスを `DeltaPage` に解析する純ロジック。
/// 画像判定・撮影日時（time_taken ?? client_modified）・media_info からの座標抽出・
/// 削除/サブフォルダの振り分けを担う。`DropboxSyncEngine` から分離してテスト可能にする。
public enum DeltaPageParser {

    /// Cloud 一覧に載る画像拡張子の**唯一の出典**。
    /// ⚠️ public なのは、バックアップ側が付けるファイル名の拡張子をここに揃えるため
    /// （この集合に無い名前で上げると、その写真は Cloud 一覧から消える＝共有もできない）。
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "webp", "avif", "jfif"
    ]

    /// 動画として一覧に載せる拡張子の**唯一の出典**（ADR-282）。
    ///
    /// スマホ（iPhone の mov・Android の mp4/3gp/webm/mkv）、ガラケー（3gp/3g2）、
    /// ビデオカメラ（AVCHD の mts/m2ts・DV・MPEG）、PC の古い形式（avi/wmv/flv/rm）まで拾う。
    /// ⚠️ **ここに載る＝再生できる、ではない**。iOS が再生できるのは mov/mp4/m4v/3gp 系が中心で、
    /// それ以外は全画面で「この形式は再生できない」と出して Dropbox で開く道を示す
    /// （再生できるかは拡張子で決め打ちせず、実際に開いて確かめる＝`VideoPlaybackView`）。
    /// ⚠️ **他の用途と衝突する拡張子は入れない**: `ts`（TypeScript）・`mod`（音楽のモジュール）。
    /// コードや音楽を Dropbox に置いている人の一覧に、開けない「動画」が並ぶため。
    public static let videoExtensions: Set<String> = [
        "mov", "qt", "mp4", "m4v", "3gp", "3gpp", "3g2", "3gp2",
        "avi", "mkv", "webm", "wmv", "asf", "flv", "f4v",
        "mpg", "mpeg", "mpe", "m1v", "m2v", "vob",
        "mts", "m2ts", "m2t", "dv", "ogv", "rm", "rmvb", "divx", "mxf", "insv"
    ]

    /// 写真か動画か（どちらでもなければ nil＝一覧に載せない）。大文字小文字は問わない。
    public static func mediaKind(forPath path: String) -> DropboxMediaKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

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
                let size: Int64?
                enum CodingKeys: String, CodingKey {
                    case tag = ".tag"; case name; case path_lower; case content_hash
                    case client_modified; case media_info; case size
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
            guard let kind = mediaKind(forPath: filePath) else { return nil }
            // 撮影日時は time_taken を優先し、無ければ client_modified。撮影地は media_info の location。
            let mediaMetadata = entry.media_info?.metadata
            let timeTaken = mediaMetadata?.time_taken.flatMap { dateFormatter.date(from: $0) }
            let modified = entry.client_modified.flatMap { dateFormatter.date(from: $0) }
            let location = mediaMetadata?.location
            return DropboxFileItem(
                path: filePath, name: name, contentHash: entry.content_hash,
                captureDate: timeTaken ?? modified,
                latitude: location?.latitude, longitude: location?.longitude,
                video: kind == .video
                    ? DropboxVideoInfo(duration: mediaMetadata?.durationSeconds, byteSize: entry.size)
                    : nil)
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

/// Dropbox の一覧に載せるファイルの種類。
public enum DropboxMediaKind: Sendable, Equatable {
    case image
    case video
}
