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
    public func loadBackupMetadata(from folderPath: String, force: Bool = false) async {
        await loadBackupMetadata(from: [folderPath], force: force)
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
    /// - Parameter force: 「メタデータ不在」の記録を無視して必ず問い合わせる（ADR-82）。
    ///   ユーザーがバックアップ画面を開いたときなど、最新を確実に取りたい場面で true にする。
    public func loadBackupMetadata(from folderPaths: [String], force: Bool = false) async {
        // 対象 JSON のパス一覧（各ルートの v1 ＋ カタログ経由のシャード）と、その rev の出どころ。
        // カタログ自体は小さいので fetchCachedJSON で取得しつつシャード一覧を得る。
        //
        // ⚠️⚠️ **rev は 1 回の一覧でまとめて取る**（ADR-255・実機ログ diagnostics-105）。
        // 以前は JSON 1 本ごとに `get_metadata` を 1 往復していた。シャードは撮影月ごとなので
        // **ライブラリが育つほど増える**——実機では 126 シャード＋カタログ＋v1 で
        // **毎起動 127 往復（各 200ms 前後・計 25 秒ぶん）**、しかもログは
        // `loaded 16792 entries (126 file(s), rev-cached)` ＝**全部「変わっていない」と
        // 分かるためだけ**に払っていた。CLAUDE.md の「往復はまとめる」に正面から反する形で、
        // ADR-119（1 回ぶんに見える呼び出しが規模に比例していた）と同じ構造。
        var targets: [(path: String, rev: RevSource)] = []
        for folderPath in folderPaths {
            // `.mosaic/` 配下（v1・カタログ・`meta/` のシャード）を 1 回の一覧で把握する。
            // 取れなければ `.ask`＝従来どおり 1 本ずつ訊く（通信不可・権限なしでも挙動を変えない）。
            let index = await metadataRevIndex(root: folderPath)
            func source(_ path: String) -> RevSource {
                guard let index else { return .ask }
                return .known(index[path.lowercased()])
            }
            let v1Path = folderPath + DropboxInternalConstants.backupMetadataSuffix
            targets.append((v1Path, source(v1Path)))
            let catalogPath = folderPath + BackupMetadataV2.catalogSuffix
            if let catalog: BackupCatalog = await fetchCachedJSON(path: catalogPath, force: force,
                                                                  rev: source(catalogPath)) {
                for shard in catalog.shards {
                    let p = folderPath + BackupMetadataV2.shardSuffix(shard)
                    targets.append((p, source(p)))
                }
            }
        }
        // v1・シャードを並列取得（rev 一致ならキャッシュ＝一覧で分かっていれば通信ゼロ）。
        // ⚠️ 結果は**完了順ではなく `targets` の並び順**（各ルートの v1 → そのルートのシャード群）
        //    でスロットへ収める。v1 は凍結され更新は v2 シャードにだけ入るので、完了順に積むと
        //    v1 の取得が遅れたときに古い v1 が新しい v2 を上書きしてしまう（diagnostics: ADR-38 読み込み側）。
        let slots: [DropboxBackupMetadata?] = await withTaskGroup(
            of: (Int, DropboxBackupMetadata?).self, returning: [DropboxBackupMetadata?].self
        ) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { [weak self] in
                    (index, await self?.fetchCachedJSON(path: target.path, force: force,
                                                        rev: target.rev))
                }
            }
            var out = [DropboxBackupMetadata?](repeating: nil, count: targets.count)
            for await (index, part) in group { out[index] = part }
            return out
        }
        let fetchedCount = slots.compactMap { $0 }.count
        guard fetchedCount > 0 else {
            DropboxLogger.info("loadBackupMetadata() — no metadata found (\(folderPaths.joined(separator: ", ")))")
            return
        }
        // マージはオフメインで（数万エントリの辞書結合をメインに載せない）。
        // 順序に意味がある＝後ろほど新しい（`BackupMetadataMerging` のコメント参照）。
        let merged = await Task.detached(priority: .userInitiated) {
            BackupMetadataMerging.merge(ordered: slots)
        }.value
        backupMetadata = merged
        // ⚠️ **効きが見える形で出す**（ADR-250/251/254）。`asked` が 0 なら一覧 1 回で
        // 全部の rev が分かった＝127 往復が消えている。0 でなければ一覧が取れていない
        // （通信不調・フォルダ無し）ので、そのぶん往復している。
        let asked = targets.reduce(0) { if case .ask = $1.rev { return $0 + 1 } else { return $0 } }
        DropboxLogger.info("loadBackupMetadata() — loaded \(merged.entries.count) entries "
                           + "(\(fetchedCount) file(s), rev-cached, get_metadata=\(asked)/\(targets.count))")
    }

    /// rev ベースのローカルキャッシュつき JSON 取得（A2）。
    /// 1) `files/get_metadata` で rev を確認（1 RPC・数百バイト）
    /// 2) 前回 rev と一致 → ローカルキャッシュから**オフメインで**デコード（本文 DL なし）
    /// 3) 不一致/初回 → ダウンロードしてキャッシュ保存＋rev 記録
    /// ファイルが存在しない・エラー時は nil。
    private struct MetaRevBody: Encodable { let path: String }
    private struct MetaRevResponse: Decodable { let rev: String? }
    private struct MetaDownloadArg: Encodable { let path: String }

    /// その JSON の rev が**もう分かっているか**。
    ///
    /// ⚠️ `.ask` と `.known(nil)` を混ぜない（ADR-207 と同じ規律）。
    /// - `.ask`: **分からない**（一覧が取れなかった）→ 1 本だけ `get_metadata` で訊く
    /// - `.known(nil)`: 一覧に**無かった**＝そのファイルは存在しない（往復は要らない）
    /// - `.known(rev)`: 一覧から分かっている（往復は要らない）
    private enum RevSource {
        case ask
        case known(String?)
    }

    /// `<root>/.mosaic` を 1 回（＋継続）だけ一覧し、配下の全ファイルの rev を返す（ADR-255）。
    /// 取れなければ nil＝呼び出し側は従来どおり 1 本ずつ訊く。
    ///
    /// ⚠️ `recursive: true` が要る——シャードは `.mosaic/meta/` の中にある。
    private func metadataRevIndex(root: String) async -> [String: String]? {
        struct ListBody: Encodable {
            let path: String
            let recursive = true
            let limit = DropboxInternalConstants.listFolderPageLimit
        }
        struct ContinueBody: Encodable { let cursor: String }
        struct Entry: Decodable {
            let tag: String?
            let path_lower: String?
            let rev: String?
            enum CodingKeys: String, CodingKey { case tag = ".tag", path_lower, rev }
        }
        struct Page: Decodable { let entries: [Entry]; let cursor: String?; let has_more: Bool? }

        var out: [String: String] = [:]
        var cursor: String?
        // ⚠️ 上限を置く（壊れた応答で無限に回らないように）。シャードが 2,000 を超えたら
        //    一覧は諦めて従来の 1 本ずつへ落ちる＝遅くなるだけで壊れない。
        for _ in 0..<10 {
            let data: Data?
            if let cursor {
                data = try? await apiClient.rpc(
                    url: DropboxInternalConstants.listFolderContinueURL,
                    jsonBody: (try? JSONEncoder().encode(ContinueBody(cursor: cursor))) ?? Data())
            } else {
                guard let body = try? JSONEncoder().encode(ListBody(path: root + "/.mosaic"))
                else { return nil }
                data = try? await apiClient.rpc(url: DropboxInternalConstants.listFolderURL,
                                                jsonBody: body)
            }
            // ⚠️⚠️ **取れなかったら nil**（＝分からない）。ここで「空の索引」を返すと、
            //    呼び出し側は全パスを `.known(nil)`＝**存在しない**と読み、
            //    通信が不調な起動では**在るメタデータを無いことにしてしまう**
            //    （バックアップ済みの判定が全部ひっくり返る）。
            //    フォルダ自体が無い端末も nil で `.ask` に落ちるが、そこは
            //    `BackupMetadataAbsence`（ADR-82）が往復を省くので安い。
            //    ⚠️ 継続の途中で失敗した場合も**部分的な索引を返さない**
            //    ——後ろのシャードが「無い」ことになり、同じ嘘が静かに混ざる。
            guard let data, let page = try? JSONDecoder().decode(Page.self, from: data) else {
                return nil
            }
            for e in page.entries where e.tag == "file" {
                if let p = e.path_lower, let rev = e.rev { out[p] = rev }
            }
            guard page.has_more == true, let next = page.cursor else { return out }
            cursor = next
        }
        return out
    }

    private func fetchCachedJSON<T: Decodable & Sendable>(path: String, force: Bool = false,
                                                          rev: RevSource = .ask) async -> T? {
        let cacheDir = Self.metadataCacheDirectory
        let cacheFile = cacheDir.appendingPathComponent(
            path.lowercased().data(using: .utf8)!.base64EncodedString()
                .replacingOccurrences(of: "/", with: "_") + ".json")
        let revKey = "backupMetaRev:" + path.lowercased()

        // 0) リモートの rev を得る。
        //    ⚠️ 一覧から分かっているなら往復しない（ADR-255）。「無い」ことも分かっているので、
        //    `BackupMetadataAbsence` の記録（ADR-82・往復を省くための推測）より一覧を優先する。
        var remoteRev: String?
        switch rev {
        case .known(let known):
            // 一覧が答えている＝この起動の事実。記録も合わせて正しておく
            // （次に一覧が取れなかった起動で、古い「無い」が効かないように）。
            if let known {
                remoteRev = known
                BackupMetadataAbsence.markPresent(path: path)
            } else {
                BackupMetadataAbsence.markAbsent(path: path)
                return nil
            }
        case .ask:
            // 「無い」ことが分かっている間は探しに行かない（ADR-82）。
            if !force, BackupMetadataAbsence.isAbsent(path: path) { return nil }
            // 1 本だけ `get_metadata`（取得できない＝ファイル自体が無い/通信不可）。
            if let body = try? JSONEncoder().encode(MetaRevBody(path: path)),
               let data = try? await apiClient.rpc(url: DropboxInternalConstants.getMetadataURL,
                                                   jsonBody: body),
               let meta = try? JSONDecoder().decode(MetaRevResponse.self, from: data) {
                remoteRev = meta.rev
            }
            guard remoteRev != nil else {
                BackupMetadataAbsence.markAbsent(path: path)   // 次回以降の往復を省く
                return nil
            }
            BackupMetadataAbsence.markPresent(path: path)      // 見つかった＝記録を消す
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
