#if canImport(UIKit)
import Foundation
import MosaicSupport

// DropboxPhotoStore のバックアップメタデータ読み込み（v1 metadata.json ＋ v2 カタログ/月別シャード・
// rev ベースのローカルキャッシュ＝ADR-38/41）。本体 store から分離した独立関心事。
extension DropboxPhotoStore {

    /// バックアップメタデータを読み込んで `backupMetadata` に保持する。
    /// v1（凍結された `.mosaic/metadata.json`）をベースに、v2（`.mosaic/catalog.json`＋
    /// 月別シャード）を**上書きマージ**する（ADR-38）。どちらも無ければ nil のまま。
    /// バックアップ完了後、または起動時に呼び出す。
    public func loadBackupMetadata(from folderPath: String) async {
        await loadBackupMetadata(from: [folderPath])
    }

    /// 複数ルート版（ADR-41）。端末フォルダ導入後は「バックアップルート（旧・フラット時代の
    /// 既存分）＋この端末のフォルダ」の 2 箇所を統合して読む。
    ///
    /// A2 パフォーマンス: 旧実装は毎起動で v1 metadata.json（最大 15〜25MB）＋全シャードを
    /// **逐次**ダウンロードし **MainActor 上で**デコードしていた。現実装は
    /// (1) 各 JSON の **rev**（Dropbox の版数）を get_metadata で確認し、前回と同じなら
    ///     ローカルキャッシュ（Caches/DropboxKit/backup-metadata/）を使う（本文 DL なし）
    /// (2) 変わった分だけダウンロード（v1・シャードは**並列**）
    /// (3) デコード・マージは **Task.detached（オフメイン）** で行い、完成値だけをメインへ
    public func loadBackupMetadata(from folderPaths: [String]) async {
        // 対象 JSON のパス一覧（各ルートの v1 ＋ カタログ経由のシャード）。
        // カタログ自体は小さいので fetchCachedJSON で取得しつつシャード一覧を得る。
        var jsonPaths: [String] = []
        for folderPath in folderPaths {
            jsonPaths.append(folderPath + DropboxInternalConstants.backupMetadataSuffix)
            let catalogPath = folderPath + BackupMetadataV2.catalogSuffix
            if let catalog: BackupCatalog = await fetchCachedJSON(path: catalogPath) {
                jsonPaths.append(contentsOf: catalog.shards.map {
                    folderPath + BackupMetadataV2.shardSuffix($0)
                })
            }
        }
        // v1・シャードを並列取得（rev 一致ならキャッシュ＝通信は get_metadata 1 往復のみ）。
        let parts: [DropboxBackupMetadata] = await withTaskGroup(
            of: DropboxBackupMetadata?.self, returning: [DropboxBackupMetadata].self
        ) { group in
            for path in jsonPaths {
                group.addTask { [weak self] in
                    await self?.fetchCachedJSON(path: path)
                }
            }
            var out: [DropboxBackupMetadata] = []
            for await part in group {
                if let part { out.append(part) }
            }
            return out
        }
        guard !parts.isEmpty else {
            DropboxLogger.info("loadBackupMetadata() — no metadata found (\(folderPaths.joined(separator: ", ")))")
            return
        }
        // マージはオフメインで（数万エントリの辞書結合をメインに載せない）。
        // エントリのキーは「実際に保存されたパス」なので、ファイル間で重複するキーは
        // 同一写真の同一エントリ＝マージ順序に意味はない。
        let merged = await Task.detached(priority: .userInitiated) {
            var out = DropboxBackupMetadata()
            for part in parts { out = out.merging(part.entries) }
            return out
        }.value
        backupMetadata = merged
        DropboxLogger.info("loadBackupMetadata() — loaded \(merged.entries.count) entries (\(parts.count) file(s), rev-cached)")
    }

    /// rev ベースのローカルキャッシュつき JSON 取得（A2）。
    /// 1) `files/get_metadata` で rev を確認（1 RPC・数百バイト）
    /// 2) 前回 rev と一致 → ローカルキャッシュから**オフメインで**デコード（本文 DL なし）
    /// 3) 不一致/初回 → ダウンロードしてキャッシュ保存＋rev 記録
    /// ファイルが存在しない・エラー時は nil。
    private struct MetaRevBody: Encodable { let path: String }
    private struct MetaRevResponse: Decodable { let rev: String? }
    private struct MetaDownloadArg: Encodable { let path: String }

    private func fetchCachedJSON<T: Decodable & Sendable>(path: String) async -> T? {
        let cacheDir = Self.metadataCacheDirectory
        let cacheFile = cacheDir.appendingPathComponent(
            path.lowercased().data(using: .utf8)!.base64EncodedString()
                .replacingOccurrences(of: "/", with: "_") + ".json")
        let revKey = "backupMetaRev:" + path.lowercased()

        // 1) リモートの rev を確認（取得できない＝ファイル自体が無い/通信不可）。
        var remoteRev: String?
        if let body = try? JSONEncoder().encode(MetaRevBody(path: path)),
           let data = try? await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL, jsonBody: body),
           let meta = try? JSONDecoder().decode(MetaRevResponse.self, from: data) {
            remoteRev = meta.rev
        }
        guard let remoteRev else { return nil }

        // 2) rev 一致ならキャッシュから（オフメインでデコード）。
        if UserDefaults.standard.string(forKey: revKey) == remoteRev,
           let cached = await Task.detached(priority: .userInitiated, operation: {
               guard let data = try? Data(contentsOf: cacheFile) else { return nil as T? }
               return try? JSONDecoder().decode(T.self, from: data)
           }).value {
            return cached
        }

        // 3) ダウンロード → オフメインでデコード → キャッシュ保存。
        guard let argString = encodeDropboxAPIArg(MetaDownloadArg(path: path)),
              let data = try? await apiClient.contentDownload(
                  url: DropboxInternalConstants.downloadFileURL, apiArg: argString) else { return nil }
        // バックアップメタデータの JSON デコードは UI が直接待つ処理ではない＝ .utility へ（提案2）。
        let decoded = await Task.detached(priority: .utility, operation: {
            try? JSONDecoder().decode(T.self, from: data)
        }).value
        guard let decoded else { return nil }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: cacheFile)
        UserDefaults.standard.set(remoteRev, forKey: revKey)
        return decoded
    }

    /// メタデータキャッシュの置き場（Caches 配下＝OS が容量逼迫時に破棄してよい）。
    private static var metadataCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DropboxKit/backup-metadata", isDirectory: true)
    }
}
#endif
