import DropboxCore
import Foundation

/// アップロード結果の分類。
/// v2（ADR-40）: 「済み」判定は HTTP 200 だけでなく **content_hash の一致**を要求する。
enum BackupUploadResult: Equatable {
    /// 検証済みアップロード完了（応答の content_hash がローカル計算値と一致）。
    /// `path` は実際に保存されたパス（409 → autorename 時は要求と異なる）。
    case uploaded(path: String, contentHash: String)
    /// HTTP 200 だが応答の content_hash がローカル計算値と不一致（＝壊れて保存された疑い）。
    /// **絶対に「済み」記録にしてはいけない**（オフロードで消すと永久喪失）。
    case hashMismatch(expected: String, actual: String?)
    /// 同パスに既存ファイルあり（呼び出し側が get_metadata で同一性を確認する）。
    case alreadyExists
    case error(Int, String)
    case networkError(String)
}

/// Dropbox 上のファイルの実体情報（`files/get_metadata`）。オフロード前検証に使う。
struct RemoteFileInfo: Equatable {
    let contentHash: String?
    let size: Int?
}

/// Dropbox への写真本体 / metadata のアップロードと実体検証（HTTP のみ）。
/// `BackupEngine` から分離し、認証・SwiftData・状態管理から独立させてテスト可能にする。
struct DropboxBackupUploader {
    let httpClient: HTTPClient

    private static let uploadURL = "https://content.dropboxapi.com/2/files/upload"
    private static let downloadURL = "https://content.dropboxapi.com/2/files/download"
    private static let getMetadataURL = "https://api.dropboxapi.com/2/files/get_metadata"

    /// パスのファイルをダウンロードする（メタデータ v2 のシャード/カタログ読み込み用）。
    /// 存在しない・エラー時は nil（呼び出し側は「初回＝空から作る」として扱う）。
    func download(path: String, token: String) async -> Data? {
        struct Arg: Encodable { let path: String }
        guard let argStr = encodeDropboxAPIArg(Arg(path: path)) else { return nil }
        var req = URLRequest(url: URL(string: Self.downloadURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(argStr, forHTTPHeaderField: "Dropbox-API-Arg")
        req.timeoutInterval = 60
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Dropbox 上のファイル実体情報（content_hash / size）を取得する。
    /// 存在しない・エラー時は nil。**オフロード前検証の要**：「今この瞬間、同一バイト列が
    /// クラウドに実在する」ことの確認に使う（記録の hash ではなくリモートの実測を見る）。
    func getMetadata(path: String, token: String) async -> RemoteFileInfo? {
        struct Body: Encodable { let path: String }
        guard let body = try? JSONEncoder().encode(Body(path: path)) else { return nil }
        var req = URLRequest(url: URL(string: Self.getMetadataURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 60
        guard let (data, resp) = try? await httpClient.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Meta: Decodable { let content_hash: String?; let size: Int? }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
        return RemoteFileInfo(contentHash: meta.content_hash, size: meta.size)
    }

    /// バックアップフォルダ以下の**実ファイル一覧**（path_lower → content_hash）を再帰取得する。
    /// 照合（reconcile）用: 記録・台帳を Dropbox の実態に合わせる出典。エラー時は nil、
    /// フォルダ未作成（not_found）は空辞書（＝ファイルなし）。
    func listFolder(root: String, token: String) async -> [String: String]? {
        struct StartBody: Encodable { let path: String; let recursive = true; let limit = 2000 }
        struct ContinueBody: Encodable { let cursor: String }
        struct Entry: Decodable {
            let tag: String; let path_lower: String?; let content_hash: String?
            enum CodingKeys: String, CodingKey { case tag = ".tag", path_lower, content_hash }
        }
        struct Resp: Decodable { let entries: [Entry]; let cursor: String; let has_more: Bool }

        var out: [String: String] = [:]
        var cursor: String?
        repeat {
            let url = cursor == nil
                ? "https://api.dropboxapi.com/2/files/list_folder"
                : "https://api.dropboxapi.com/2/files/list_folder/continue"
            let body: Data?
            if let cursor {
                body = try? JSONEncoder().encode(ContinueBody(cursor: cursor))
            } else {
                body = try? JSONEncoder().encode(StartBody(path: root))
            }
            guard let body else { return nil }
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = 60
            guard let (data, resp) = try? await httpClient.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode else { return nil }
            if code == 409 {
                // フォルダ自体が無い＝ファイルゼロ（初回照合・Dropbox 側で全削除された等）。
                return cursor == nil ? [:] : nil
            }
            guard code == 200, let parsed = try? JSONDecoder().decode(Resp.self, from: data) else {
                return nil
            }
            for entry in parsed.entries where entry.tag == "file" {
                if let path = entry.path_lower { out[path] = entry.content_hash ?? "" }
            }
            cursor = parsed.has_more ? parsed.cursor : nil
        } while cursor != nil
        return out
    }

    /// 写真本体をアップロードする（ADR-40: 検証つき）。
    /// - `expectedHash`: ローカルで計算した content_hash。応答の hash と**一致して初めて成功**。
    /// - `autorename`: 409（同パス既存）時に別名保存を許可するか。既定 false（初回試行）。
    ///   呼び出し側は 409 → `getMetadata` で同一性確認 → 不一致なら autorename=true で再試行する。
    func upload(data: Data, to path: String, token: String,
                expectedHash: String, autorename: Bool = false) async -> BackupUploadResult {
        struct Arg: Encodable {
            let path: String
            let mode = "add"
            let autorename: Bool
            let mute = true
        }
        guard let argStr = encodeDropboxAPIArg(Arg(path: path, autorename: autorename)) else {
            return .error(-1, "Failed to encode Dropbox-API-Arg for path: \(path)")
        }
        let req = Self.makeRequest(argStr: argStr, body: data, token: token, timeout: 300)
        do {
            let (responseData, resp) = try await httpClient.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200:
                // 応答の content_hash / path を検証。200 でも hash 不一致なら「済み」にしない
                // （通信・保存の破損検出。旧実装は 200 を無条件に成功扱いしていた）。
                struct UploadResp: Decodable { let content_hash: String?; let path_lower: String? }
                let parsed = try? JSONDecoder().decode(UploadResp.self, from: responseData)
                let actual = parsed?.content_hash
                guard actual == expectedHash else {
                    return .hashMismatch(expected: expectedHash, actual: actual)
                }
                return .uploaded(path: parsed?.path_lower ?? path.lowercased(), contentHash: expectedHash)
            case 409:
                return .alreadyExists
            default:
                let body = String(data: responseData, encoding: .utf8) ?? "(non-UTF8 body)"
                return .error(code, body)
            }
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// 構築済み `metadata` を `mode=overwrite` で送信する。結果を要約文字列で返す。
    func uploadMetadata(_ metadata: DropboxBackupMetadata, to metaPath: String, token: String) async -> String {
        await uploadJSON(metadata, to: metaPath, token: token)
    }

    /// overwrite アップロード用の Dropbox-API-Arg（ジェネリック関数内に型をネストできないため外出し）。
    private struct OverwriteArg: Encodable {
        let path: String
        let mode = "overwrite"
        let mute = true
    }

    /// 任意の Encodable を JSON で overwrite アップロードする（v2 カタログ/シャード用）。
    /// 戻り値は表示用の結果文字列。
    func uploadJSON<T: Encodable>(_ value: T, to path: String, token: String) async -> String {
        guard let jsonData = try? JSONEncoder().encode(value) else {
            return "failed (JSON encode error)"
        }
        guard let argStr = encodeDropboxAPIArg(OverwriteArg(path: path)) else {
            return "failed (arg encode error)"
        }
        let req = Self.makeRequest(argStr: argStr, body: jsonData, token: token, timeout: 60)
        do {
            let (respData, resp) = try await httpClient.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                return "OK (\(jsonData.count) bytes)"
            } else {
                let body = String(data: respData, encoding: .utf8) ?? ""
                return "HTTP \(code): \(BackupPlanning.dropboxErrorSummary(from: body))"
            }
        } catch {
            return "network error: \(error.localizedDescription)"
        }
    }

    /// ⚠️ Dropbox-API-Arg ヘッダーには必ず `encodeDropboxAPIArg()` の結果を使うこと。
    /// JSONEncoder の出力をそのまま setValue すると、非ASCII文字を URLSession が
    /// RFC 7230 違反として無言で破壊し、Dropbox がエラーを返す（過去に発生）。
    private static func makeRequest(argStr: String, body: Data, token: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: URL(string: uploadURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(argStr, forHTTPHeaderField: "Dropbox-API-Arg")
        req.httpBody = body
        req.timeoutInterval = timeout
        return req
    }
}
