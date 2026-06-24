import DropboxCore
import Foundation

/// アップロード結果の分類（HTTP ステータス由来）。
enum BackupUploadResult: Equatable {
    case uploaded
    case alreadyExists
    case error(Int, String)
    case networkError(String)
}

/// Dropbox への写真本体 / metadata.json のアップロード（HTTP のみ）。
/// `BackupEngine` から分離し、認証・SwiftData・状態管理から独立させてテスト可能にする。
struct DropboxBackupUploader {
    let httpClient: HTTPClient

    private static let uploadURL = "https://content.dropboxapi.com/2/files/upload"

    /// 写真本体を `mode=add` でアップロードする。
    func upload(data: Data, to path: String, token: String) async -> BackupUploadResult {
        struct Arg: Encodable {
            let path: String
            let mode = "add"
            let autorename = false
            let mute = true
        }
        guard let argStr = encodeDropboxAPIArg(Arg(path: path)) else {
            return .error(-1, "Failed to encode Dropbox-API-Arg for path: \(path)")
        }
        let req = Self.makeRequest(argStr: argStr, body: data, token: token, timeout: 300)
        do {
            let (responseData, resp) = try await httpClient.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            switch code {
            case 200: return .uploaded
            case 409: return .alreadyExists
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
        guard let jsonData = try? JSONEncoder().encode(metadata) else {
            return "failed (JSON encode error)"
        }
        struct Arg: Encodable {
            let path: String
            let mode = "overwrite"
            let mute = true
        }
        guard let argStr = encodeDropboxAPIArg(Arg(path: metaPath)) else {
            return "failed (arg encode error)"
        }
        let req = Self.makeRequest(argStr: argStr, body: jsonData, token: token, timeout: 60)
        do {
            let (respData, resp) = try await httpClient.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 {
                return "OK (\(metadata.entries.count) total entries, \(jsonData.count) bytes)"
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
