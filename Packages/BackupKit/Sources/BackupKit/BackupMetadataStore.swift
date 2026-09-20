import DropboxCore
import Foundation
import MosaicSupport

/// バックアップメタデータ v2（ADR-38）の**唯一の書き手**。
///
/// ## なぜ 1 つの型にまとめるか（ADR-200）
/// v2 の台帳は「カタログ（`<root>/.mosaic/catalog.json`）＋撮影月シャード
/// （`<root>/.mosaic/meta/<YYYY-MM>.json`）」の 2 層で、**読む側はカタログに載っている
/// シャードしか開かない**。したがって書き手には 2 つの義務がある。
///
///   1. シャードを `<root>` の下に置く
///   2. 置いたシャードをカタログに登録する
///
/// 以前はこの 2 つが呼び出し側の責任だった。バックアップ（`BackupRunner`）は両方やるが、
/// オフロード（`OffloadService`）は**どちらも守っていなかった**——
/// 書き先を「写真のパスの親」から作っていたため、写真が年月フォルダへ移った（ADR-176）あとは
/// `<root>/2025/2025-08/.mosaic/…` という誰も見ない場所へ書き、カタログにも登録しなかった。
/// しかも書き込み自体は成功するので台帳は「送信済み」になり、二度と書き直されない。
/// 結果、**オフロードした写真は再インストール後に復元できない**。
///
/// だからこの型は **`root` を持ち、パスから推測しない**。そして
/// **シャードを書いたら必ず自分でカタログを更新する**（呼び出し側に選択肢を与えない）。
struct BackupMetadataStore {
    let uploader: DropboxBackupUploader
    let token: String
    /// このメタデータ台帳が属するバックアップルート（`<設定>/<端末>/Backup`）。
    /// ⚠️ **写真の置き場（`<root>/<年>/<年-月>`）ではない。**
    let root: String

    private var catalogPath: String { root + BackupMetadataV2.catalogSuffix }
    private func shardPath(_ shard: String) -> String { root + BackupMetadataV2.shardSuffix(shard) }

    /// このパスがこの台帳の管轄か（`<root>/…`）。
    /// 管轄外のパスに印を書くと、**別の端末フォルダの台帳を壊す**ので必ず弾く。
    func owns(path: String) -> Bool {
        let lower = path.lowercased()
        let base = root.lowercased()
        return lower == base || lower.hasPrefix(base + "/")
    }

    /// 反映の結果。**書けたシャード**と**書けなかったシャード**を分けて返す。
    struct ApplyResult: Sendable {
        /// 書き込みに成功したシャード名。
        var written: [String] = []
        /// 書けなかったシャードのエントリ（再送のために呼び出し側が保持する）。
        var failed: [String: [String: DropboxBackupMetadata.Entry]] = [:]
        /// 最初の失敗の詳細（診断ログ用・"HTTP 429: too_many_write_operations" など）。
        var firstFailure: String?
        /// カタログを書けたか（書けていなければ、書けたシャードも再送キューへ戻す）。
        var catalogWritten = false
    }

    /// カタログに載せる「写真単位でない情報」。オフロードのように索引を持たない経路は
    /// `nil` を渡す——そのときカタログは**シャード一覧だけ**を更新する
    /// （空の索引で既存のアルバム名・人物名を消さない）。
    struct CatalogFacts: Sendable {
        var albums: [String]
        var people: [String]
        var albumIDs: [String: String]?
    }

    // MARK: - 書き込み

    /// シャードごとの新規/更新エントリを反映し、**続けてカタログを更新する**。
    ///
    /// ⚠️ **既存シャードの取得に失敗したら書かない**。取得失敗を「空のシャード」と読むと、
    /// 一時的な通信障害で同じ月の既存メタデータ（人物名・アルバム・位置情報・オフロードの印）が
    /// 丸ごと失われる。「無い」と「取れなかった」は download 側で区別する。
    /// - Parameter log: 進捗 1 行の通知（"meta/2025-08.json (+3 → 45): OK" 形式）。
    @discardableResult
    func apply(byShard: [String: [String: DropboxBackupMetadata.Entry]],
               facts: CatalogFacts?,
               log: (String) async -> Void) async -> ApplyResult {
        var result = ApplyResult()
        for (shard, entries) in byShard.sorted(by: { $0.key < $1.key }) {
            let path = shardPath(shard)
            // ⚠️ download→merge→upload は**シャード単位で直列化**する。オフロードの印の
            // 書き込みと並行すると、同じ旧シャードを読んだ後着が先着の変更を消す。
            let written = await MetadataShardLock.withLock(path.lowercased()) { () async -> Bool in
                let existing: Data?
                switch await uploader.downloadResult(path: path, token: token) {
                case .found(let data):
                    existing = data
                case .notFound:
                    existing = nil      // 新規シャード＝空から作ってよい
                case .failure(let reason):
                    await log("  meta/\(shard).json: skipped — could not read existing (\(reason))")
                    if result.firstFailure == nil { result.firstFailure = "read: \(reason)" }
                    return false
                }
                // ⚠️ 「200 で取れたが読めない」も**取れなかったのと同じ**に扱う。
                // 空として上書きすると、その月の人物名・アルバム・位置・印がまとめて消える。
                guard let merged = BackupMetadataPlanning.mergedShard(existing: existing,
                                                                     adding: entries) else {
                    await log("  meta/\(shard).json: skipped — existing file is not readable JSON")
                    Diagnostics.mark("backup: metadata shard unreadable — \(path)")
                    return false
                }
                let upload = await uploader.uploadJSONResult(merged, to: path, token: token)
                await log("  meta/\(shard).json (+\(entries.count) → \(merged.entries.count)): \(upload.detail)")
                if !upload.ok, result.firstFailure == nil { result.firstFailure = upload.detail }
                return upload.ok
            }
            if written {
                result.written.append(shard)
            } else {
                result.failed[shard] = entries
            }
        }
        result.catalogWritten = await updateCatalog(touched: result.written, facts: facts, log: log)
        return result
    }

    /// 既存エントリへの**部分更新**（オフロードの印）。エントリが無ければ最小形で作る。
    /// 書けたらそのシャードを**カタログにも登録する**（登録しなければ読む側は開かない）。
    /// - Returns: シャードを書けて、かつカタログにも載せられたか。
    ///   どちらか片方でも失敗したら false＝呼び出し側は「未送信」として残し、後から再送する。
    @discardableResult
    func mark(paths: [String], shard: String,
              mutate: (inout DropboxBackupMetadata.Entry) -> Void,
              makeDefault: (String) -> DropboxBackupMetadata.Entry,
              log: (String) async -> Void) async -> Bool {
        let path = shardPath(shard)
        let written = await MetadataShardLock.withLock(path.lowercased()) { () async -> Bool in
            var metadata: DropboxBackupMetadata
            switch await uploader.downloadResult(path: path, token: token) {
            case .found(let data):
                // ⚠️ デコード不能を空へ落とさない。空で上書きすると既存の人物名・アルバム・
                // 位置・他の写真の印が消える。false を返せば台帳は未送信のまま残り、再送される。
                guard let decoded = try? JSONDecoder().decode(DropboxBackupMetadata.self,
                                                              from: data) else {
                    await log("offload.marker: meta/\(shard).json skipped — "
                              + "existing file is not readable JSON")
                    Diagnostics.mark("backup: metadata shard unreadable — \(path)")
                    return false
                }
                metadata = decoded
            case .notFound:
                metadata = DropboxBackupMetadata()
            case .failure(let reason):
                await log("offload.marker: meta/\(shard).json skipped — could not read existing (\(reason))")
                return false
            }
            for p in paths {
                var entry = metadata.entries[p] ?? makeDefault(p)
                mutate(&entry)
                metadata.entries[p] = entry
            }
            let result = await uploader.uploadJSONResult(metadata, to: path, token: token)
            await log("offload.marker: meta/\(shard).json (\(paths.count) update(s)): \(result.detail)")
            return result.ok
        }
        guard written else { return false }
        // ⚠️ ここを飛ばすと「書いたのに読まれない」になる。印を書く経路はアルバム/人物の索引を
        // 持たないので `facts` は nil＝シャード一覧だけを足す。
        return await updateCatalog(touched: [shard], facts: nil, log: log)
    }

    // MARK: - カタログ

    /// 触ったシャードをカタログへ登録する（`facts` があればアルバム/人物も更新）。
    /// 触ったシャードが無く、載せる事実も無ければ**何もしない**（空の往復を省く）。
    /// - Returns: 書けたか。既存が読めない回は**書かない**（アルバム名・人物名・シャード一覧を失う）。
    private func updateCatalog(touched: [String], facts: CatalogFacts?,
                               log: (String) async -> Void) async -> Bool {
        guard !touched.isEmpty || facts != nil else { return true }
        let existing: Data?
        switch await uploader.downloadResult(path: catalogPath, token: token) {
        case .found(let data): existing = data
        case .notFound: existing = nil
        case .failure(let reason):
            await log("  catalog.json: skipped — could not read existing (\(reason))")
            return false
        }
        guard let catalog = BackupMetadataPlanning.updatedCatalog(
            existing: existing, touchedShards: touched,
            albums: facts?.albums ?? [], people: facts?.people ?? [],
            albumIDs: facts?.albumIDs,
            deviceID: BackupDeviceIdentity.currentID(),
            deviceName: BackupDeviceIdentity.currentDisplayName()) else {
            await log("  catalog.json: skipped — existing file is not readable JSON")
            Diagnostics.mark("backup: catalog unreadable — \(catalogPath)")
            return false
        }
        let result = await uploader.uploadJSONResult(catalog, to: catalogPath, token: token)
        await log("  catalog.json (shards=\(catalog.shards.count)): \(result.detail)")
        return result.ok
    }
}
