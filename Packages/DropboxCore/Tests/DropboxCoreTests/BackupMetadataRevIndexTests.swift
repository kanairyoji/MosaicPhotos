#if canImport(UIKit)
import Foundation
import Testing
@testable import DropboxCore

/// **バックアップメタデータの rev を 1 回の一覧でまとめて取る**（ADR-255）。
///
/// ## なぜこのテストが要るか（実機ログ diagnostics-105）
/// 以前は JSON 1 本ごとに `files/get_metadata` を 1 往復していた。シャードは撮影月ごとなので
/// **ライブラリが育つほど増える**——実機では 126 シャード＋カタログ＋v1 で
/// **毎起動 127 往復（各 200ms 前後・計 25 秒ぶん）**。しかもログは
/// `loaded 16792 entries (126 file(s), rev-cached)` ＝**全部「変わっていない」と分かるためだけ**
/// に払っていた。ADR-119（1 回ぶんに見える呼び出しが規模に比例していた）と同じ構造。
///
/// ⚠️⚠️ 検証するのは**時間ではなく往復の回数**（ADR-119）。時間は CI で揺れるが回数は決定的。
/// ⚠️ さらに**逆向き**（一覧が取れなかったとき）も固定する——そこを「無い」と読むと、
/// 通信が不調な起動で**在るメタデータを無いことにする**（バックアップ済みの判定が
/// 全部ひっくり返る）。今セッションで繰り返し踏んだ「分からない≠無い」と同じ形。
@Suite("バックアップメタデータの rev（往復をまとめる）", .serialized)
@MainActor
struct BackupMetadataRevIndexTests {

    /// ⚠️ rev と不在の記録は `UserDefaults.standard` に残るので、テストごとに別のルートを使う
    /// （使い回すと前のテストの rev が一致して「ダウンロードしなかった」側へ落ちる）。
    private func uniqueRoot() -> String { "/backup-\(UUID().uuidString)" }

    private let shards = (1...12).map { String(format: "2025-%02d", $0) }

    private func makeStore(responder: @escaping @Sendable (URLRequest) -> (Data, URLResponse))
        -> (DropboxPhotoStore, StubHTTPClient) {
        let auth = DropboxAuthService(appKey: "k", redirectURI: "app://cb")
        // ⚠️ トークンが無いと `rpc` が認証で落ち、**問い合わせそのものが走らない**
        //（テストが通信失敗の経路だけを通り、何も見ないまま通る）。
        auth.credential = DropboxCredential(accessToken: "t", refreshToken: nil,
                                            expiresAt: Date().addingTimeInterval(3600),
                                            accountId: "acc1", connectedAt: Date(),
                                            lastRefreshedAt: nil)
        let client = StubHTTPClient(responder: responder)
        let store = DropboxPhotoStore(auth: auth, httpClient: client,
                                      cache: DropboxCacheStore(isStoredInMemoryOnly: true))
        return (store, client)
    }

    /// ダウンロード要求のパスは `Dropbox-API-Arg` ヘッダに入っている。
    private nonisolated static func downloadedPath(_ request: URLRequest) -> String {
        guard let arg = request.value(forHTTPHeaderField: "Dropbox-API-Arg"),
              let data = arg.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["path"] as? String else { return "" }
        return path
    }

    private nonisolated static func ok(_ body: String, _ request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!)
    }

    /// 1 枚ぶんの entries を持つメタデータ JSON（v1・シャード共用）。
    /// ⚠️ `version` / `updatedAt` は必須（省くとデコードが静かに失敗し、
    /// 「往復は減ったがメタデータが nil」になる＝最初にそう書いて踏んだ）。
    private nonisolated static func metadataJSON(_ path: String) -> String {
        """
        {"version":1,"updatedAt":"2026-01-01T00:00:00Z",
         "entries":{"\(path)":{"people":["A"],"albums":[],"isFavorite":false}}}
        """
    }

    private func catalogJSON() -> String {
        let list = shards.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {"schemaVersion":2,"updatedAt":"2026-01-01T00:00:00Z","shards":[\(list)],
         "albums":[],"people":[]}
        """
    }

    /// `.mosaic` の一覧応答（v1・カタログ・全シャードの rev を 1 回で返す）。
    private func listFolderJSON(root: String) -> String {
        var entries = [
            "{\".tag\":\"file\",\"path_lower\":\"\(root.lowercased())/.mosaic/metadata.json\",\"rev\":\"r-v1\"}",
            "{\".tag\":\"file\",\"path_lower\":\"\(root.lowercased())/.mosaic/catalog.json\",\"rev\":\"r-cat\"}",
            // ⚠️ フォルダのエントリも混ざる（rev を持たない）。file だけ拾えていること。
            "{\".tag\":\"folder\",\"path_lower\":\"\(root.lowercased())/.mosaic/meta\"}",
        ]
        for s in shards {
            entries.append("{\".tag\":\"file\","
                           + "\"path_lower\":\"\(root.lowercased())/.mosaic/meta/\(s).json\","
                           + "\"rev\":\"r-\(s)\"}")
        }
        return "{\"entries\":[\(entries.joined(separator: ","))],\"has_more\":false,\"cursor\":\"c1\"}"
    }

    private func countRequests(_ requests: [URLRequest], containing needle: String) -> Int {
        requests.filter { ($0.url?.absoluteString ?? "").contains(needle) }.count
    }

    // MARK: -

    /// ⚠️⚠️ **これが本題**: 一覧が答えるなら `get_metadata` は 1 回も出さない。
    @Test("一覧 1 回で全シャードの rev が分かるなら、get_metadata は 0 往復")
    func listingReplacesPerFileMetadataCalls() async {
        let root = uniqueRoot()
        let catalog = catalogJSON()
        let listing = listFolderJSON(root: root)
        let (store, client) = makeStore { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("list_folder") { return Self.ok(listing, request) }
            if url.contains("get_metadata") { return Self.ok("{\"rev\":\"r-x\"}", request) }
            if url.contains("files/download") {
                let path = Self.downloadedPath(request)
                return Self.ok(path.hasSuffix("catalog.json") ? catalog
                               : Self.metadataJSON(path), request)
            }
            return Self.ok("{}", request)
        }

        await store.loadBackupMetadata(from: root)

        let requests = await client.recordedRequests()
        #expect(countRequests(requests, containing: "get_metadata") == 0,
                "一覧で rev が分かっているのに 1 本ずつ訊いている（127 往復の形）")
        #expect(countRequests(requests, containing: "list_folder") == 1,
                "一覧は 1 往復で足りる（12 シャード＋カタログ＋v1）")
        #expect(store.backupMetadata != nil, "往復は減ったがメタデータが読めていない")
    }

    /// 2 回目の読み込みは rev が一致するので**本文のダウンロードも消える**
    /// （＝一覧 1 往復だけになる。実機ログの `rev-cached` が意味していた状態）。
    @Test("2 回目は rev が一致し、本文のダウンロードも出さない")
    func secondLoadDownloadsNothing() async {
        let root = uniqueRoot()
        let catalog = catalogJSON()
        let listing = listFolderJSON(root: root)
        let responder: @Sendable (URLRequest) -> (Data, URLResponse) = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("list_folder") { return Self.ok(listing, request) }
            if url.contains("files/download") {
                let path = Self.downloadedPath(request)
                return Self.ok(path.hasSuffix("catalog.json") ? catalog
                               : Self.metadataJSON(path), request)
            }
            return Self.ok("{}", request)
        }
        let (first, _) = makeStore(responder: responder)
        await first.loadBackupMetadata(from: root)

        let (second, client) = makeStore(responder: responder)
        await second.loadBackupMetadata(from: root)

        let requests = await client.recordedRequests()
        #expect(countRequests(requests, containing: "files/download") == 0,
                "rev が同じなのに本文を取り直している")
        #expect(second.backupMetadata != nil, "キャッシュから読めていない")
    }

    /// ⚠️⚠️ **逆向き（危ない側）**: 一覧が取れなかった起動で「無い」と読まないこと。
    /// ここを空の索引で埋めると、通信が不調なだけの起動で**在るメタデータを無いことにする**。
    @Test("一覧が取れなかったら 1 本ずつ訊き直す（「無い」と読まない）")
    func fallsBackWhenListingFails() async {
        let root = uniqueRoot()
        let catalog = catalogJSON()
        let (store, client) = makeStore { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("list_folder") {
                // 通信不調（サーバ側の失敗）。フォルダが無いわけではない。
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 500,
                                                httpVersion: nil, headerFields: nil)!)
            }
            if url.contains("get_metadata") { return Self.ok("{\"rev\":\"r-x\"}", request) }
            if url.contains("files/download") {
                let path = Self.downloadedPath(request)
                return Self.ok(path.hasSuffix("catalog.json") ? catalog
                               : Self.metadataJSON(path), request)
            }
            return Self.ok("{}", request)
        }

        await store.loadBackupMetadata(from: root)

        let requests = await client.recordedRequests()
        #expect(countRequests(requests, containing: "get_metadata") > 0,
                "一覧が取れなかったのに 1 本も訊いていない＝「無い」と決めつけている")
        #expect(store.backupMetadata != nil,
                "一覧が取れなかっただけで、在るメタデータを読めなくなっている")
    }
}
#endif
