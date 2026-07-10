import Foundation

/// `get_thumbnail_batch` API の DTO 定義とリクエストエンコード・レスポンス（base64）デコードの
/// 純ユニット（Foundation のみ・ネットワーク/UIKit 非依存）。
/// キューイング戦略（`DropboxThumbnailBatcher`）・ネットワーク I/O（`DropboxThumbnailChunkFetcher`）
/// から分離し、単体で検証できるようにする。
enum DropboxThumbnailBatchRequest {

    // MARK: - DTO

    struct Entry: Encodable {
        let path: String
        let format: String = DropboxInternalConstants.thumbnailFormat
        let size: String = DropboxInternalConstants.thumbnailAPISize
    }
    struct BatchArg: Encodable { let entries: [Entry] }
    struct ResultEntry: Decodable {
        let tag: String
        let thumbnail: String?
        enum CodingKeys: String, CodingKey { case tag = ".tag"; case thumbnail }
    }
    struct BatchResult: Decodable { let entries: [ResultEntry] }

    // MARK: - Encode / Decode

    /// 取得対象パス一覧からリクエストボディ（JSON）を組み立てる。
    static func encodeBody(paths: [String]) -> Data? {
        try? JSONEncoder().encode(BatchArg(entries: paths.map { Entry(path: $0) }))
    }

    /// レスポンス JSON を解析し、path ごとの結果（成功=base64 復号済み Data / 失敗=nil）を
    /// リクエスト順で返す。JSON 自体の解析失敗は nil（呼び出し側が全件失敗として扱う）。
    /// entries が paths より少ない場合（異常系）は残りを失敗（nil）扱いにする。
    static func decodeResults(from data: Data, paths: [String]) -> [(path: String, imageData: Data?)]? {
        guard let result = try? JSONDecoder().decode(BatchResult.self, from: data) else { return nil }
        var results: [(path: String, imageData: Data?)] = []
        for (path, entry) in zip(paths, result.entries) {
            if entry.tag == "success",
               let b64 = entry.thumbnail,
               let imgData = Data(base64Encoded: b64) {
                results.append((path, imgData))
            } else {
                results.append((path, nil))
            }
        }
        if result.entries.count < paths.count {
            for path in paths.dropFirst(result.entries.count) {
                results.append((path, nil))
            }
        }
        return results
    }
}
