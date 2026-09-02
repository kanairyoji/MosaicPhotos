import Foundation
import MosaicSupport
import SwiftData

/// バックアップ記録の Sendable 値（actor 境界の外へ @Model を漏らさない・プロジェクト規約）。
public struct BackupRecordLite: Sendable {
    public let dropboxPath: String
    public let localIdentifier: String?
    public let filename: String
    public let creationDate: Date?
    public let contentHash: String?
    public let albums: [String]
    public let isFavorite: Bool
    public let backedUpAt: Date
}

/// BackupKit の SwiftData 永続化を一手に引き受ける actor（A1/B1 リファクタリング）。
///
/// 旧実装は `BackupEngine`（@MainActor）が plain な `ModelContext` を直接使っており、
/// **起動時の全記録 fetch×2・バックアップ中の毎枚 save・照合の全件 fetch がメインスレッド**で
/// 走っていた（AutoAlbumStore で実測 14.5s ハングを起こした「SwiftData をメインで」の同型）。
/// ⚠️ 実行スレッドは `unownedExecutor`（専用シリアルキュー）で断つ——`@ModelActor` の既定 executor は
/// **呼び出し元のスレッド**でジョブを走らせるため、それが無いと MainActor からの呼び出しがメインで走る
/// （`ModelStoreExecutor` に詳述）。生成も `makeDetached()` を使う（コンテナを開くディスク I/O をメインから外す）。
@ModelActor
public actor BackupStore {
    /// ⚠️ **専用のシリアルキューで走らせる**（`ModelStoreExecutor` に理由を詳述）。
    /// SwiftData の既定 executor はジョブを**呼び出し元のスレッド**で実行するため、これが無いと
    /// MainActor からの `await store.…` が**メインスレッドで**走る（実測の前面ハングの真因）。
    private nonisolated let executorQueue = ModelStoreExecutor.serialQueue(label: "com.mosaicphotos.store.backup")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executorQueue.asUnownedSerialExecutor() }

    /// テスト用: このストアのジョブがメインスレッドで走っていないかを確かめる
    /// （`unownedExecutor` の回帰検証。`ModelActorExecutorTests` から呼ぶ）。
    func runsOnMainThreadForTesting() -> Bool { Thread.isMainThread }


    /// オフメイン生成ファクトリ。コンテナを開く（＝ストアファイルを触る）ディスク I/O を
    /// メインから外す。実行スレッドの分離は `unownedExecutor` の役目で、生成側では決まらない。
    public static func makeDetached() async -> BackupStore {
        await Task.detached(priority: .userInitiated) {
            BackupStore(modelContainer: makeContainer())
        }.value
    }

    /// テスト用のインメモリコンテナ（本番コンテナと同じスキーマ・ディスクに触れない）。
    public static func inMemoryContainerForTesting() -> ModelContainer {
        let schema = Schema([BackupAssetRecord.self, OffloadRecord.self,
                             ShareSet.self, ShareItem.self])
        // ⚠️ インメモリ構成は**名前を変えないとプロセス内で同じストアを共有する**
            // （テストが並列に走ると別スイートの行が流れ込む・FaceStore で実際に踏んだ）。
            let config = ModelConfiguration(UUID().uuidString, schema: schema,
                                            isStoredInMemoryOnly: true)
        // テスト専用なので失敗は致命的（本番の自己修復とは別扱い）。
        return try! ModelContainer(for: schema, configurations: [config])
    }

    /// 名前付き永続コンテナ（自己修復）。壊れた/非互換ストアは削除して再構築し、
    /// それでも駄目ならインメモリ（起動を止めない・記録は 409→hash 照合で自然復元）。
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([BackupAssetRecord.self, OffloadRecord.self,
                             ShareSet.self, ShareItem.self])
        // 台帳（バックアップ記録・オフロード・共有状態）。壊れても**消さずに退避**する。
        return makeResilientModelContainer(
            name: "BackupKit", schema: schema, policy: .ledger,
            openFailedMessage: "BackupStore: 'BackupKit' store open failed; quarantining and rebuilding.",
            memoryFallbackMessage: "BackupStore: 'BackupKit' store still failing; using in-memory store.",
            log: { BackupLogger.error($0) })
    }

    // MARK: - Backup records

    /// アップロード成功 1 件の upsert（パスがキー・再アップロードは最新情報で上書き）。
    /// - Returns: **永続化できたか**。false のときは進捗台帳へ入れてはいけない
    ///   （台帳にだけ載ると「再アップロードされないのに記録が無い」写真になる・レビュー指摘）。
    @discardableResult
    public func upsertRecord(dropboxPath: String, localIdentifier: String?, filename: String,
                             creationDate: Date?, contentHash: String?,
                             people: [String], albums: [String], isFavorite: Bool) -> Bool {
        let path = dropboxPath.lowercased()
        let descriptor = FetchDescriptor<BackupAssetRecord>(
            predicate: #Predicate { $0.dropboxPath == path })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.people     = people
            existing.albums     = albums
            existing.isFavorite = isFavorite
            existing.backedUpAt = Date()
            if let contentHash { existing.contentHash = contentHash }
            // ⚠️ **実体の対応も現在の PHAsset へ付け替える**（レビュー指摘）。
            // 同じ写真を端末から削除して再取り込みすると localIdentifier が変わる。実体は
            // 同じなので 409→content_hash 一致で「済み」扱いになりここへ来るが、旧実装は
            // localIdentifier を据え置いたため、記録は**消えた旧 ID** を指したまま残った。
            // 一方 runner は新 ID を進捗台帳へ入れる＝以後この写真は pending に入らず
            // 自己修復しない。結果、共有（backupRefs）・localToCloudPaths・backupCopyIndex・
            // オフロード候補（記録 ID → PHAsset 解決）のすべてが新 ID を解決できなくなる。
            // 同一パス＝同一 content_hash は検証済みなので、その Dropbox 副本に対応する
            // 「生きている PHAsset」は**最後に検証できた方**が正しい、という規則にする。
            // （バイト列も名前も同一の重複写真が 2 枚ある場合は last-writer-wins になる。
            //   従来は first-writer-wins だったが、どちらでも記録は 1 件のまま。）
            if let localIdentifier { existing.localIdentifier = localIdentifier }
            existing.filename     = filename
            existing.creationDate = creationDate
        } else {
            modelContext.insert(BackupAssetRecord(
                dropboxPath: dropboxPath, localIdentifier: localIdentifier,
                filename: filename, creationDate: creationDate,
                contentHash: contentHash, people: people, albums: albums, isFavorite: isFavorite))
        }
        do {
            try modelContext.save()
            return true
        } catch {
            BackupLogger.error("upsertRecord: save failed — \(error)")
            modelContext.rollback()
            return false
        }
    }

    /// 副本の判定と**撮影日の復元**に要る 3 列だけの射影（パス小文字 → 記録）。
    ///
    /// ⚠️ 撮影日が要る理由（ADR-128 追補・実フィードバック）: Dropbox 側の撮影日は
    /// `time_taken ?? client_modified` で、**EXIF から media_info が付かない**（あるいは同期時に
    /// pending だった）写真では**アップロード時刻**になる。すると「去年の写真」が一覧の先頭
    /// （最新）に出る。アプリの台帳は元の `PHAsset.creationDate` を持っているので、
    /// **こちらを正**として表示側で上書きする——既にアップロード済みの写真も直る点が肝。
    public func backupCopyRecords() -> [String: BackupCopyRecord] {
        var d = FetchDescriptor<BackupAssetRecord>()
        d.propertiesToFetch = [\.dropboxPath, \.localIdentifier, \.creationDate]
        let rows = (try? modelContext.fetch(d)) ?? []
        var out: [String: BackupCopyRecord] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            out[row.dropboxPath.lowercased()] = BackupCopyRecord(
                localIdentifier: row.localIdentifier, captureDate: row.creationDate)
        }
        return out
    }

    /// 二重表示の判定に要る **2 列だけ**の射影（Dropbox パス小文字 → localIdentifier）。
    ///
    /// ⚠️ `allRecordsLite()` は全カラム（ファイル名・hash・アルバム・日付…）を materialize する。
    /// 重複判定に要るのは 2 列だけなので、起動時にそれを全件立ち上げるのは無駄な山になる
    /// （メモリの実測で 1GB 級のクラッシュを経験しているので、常駐経路の確保は最小にする）。
    public func backupCopyIndex() -> [String: String] {
        var d = FetchDescriptor<BackupAssetRecord>()
        d.propertiesToFetch = [\.dropboxPath, \.localIdentifier]
        let rows = (try? modelContext.fetch(d)) ?? []
        var out: [String: String] = [:]
        out.reserveCapacity(rows.count)
        for row in rows {
            // localIdentifier が無い記録（旧形式・取り込み由来）は突合できない＝隠さない。
            guard let localID = row.localIdentifier else { continue }
            out[row.dropboxPath.lowercased()] = localID
        }
        return out
    }

    /// 全記録（Sendable 値・撮影日昇順）。
    public func allRecordsLite() -> [BackupRecordLite] {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>(
            sortBy: [SortDescriptor(\.creationDate, order: .forward)]))) ?? []
        return records.map { r in
            BackupRecordLite(dropboxPath: r.dropboxPath, localIdentifier: r.localIdentifier,
                             filename: r.filename, creationDate: r.creationDate,
                             contentHash: r.contentHash, albums: r.albums,
                             isFavorite: r.isFavorite, backedUpAt: r.backedUpAt)
        }
    }

    /// 記録にある localIdentifier 集合（済み判定の確かな出典・台帳消失時の自己修復用）。
    public func recordedLocalIdentifiers() -> Set<String> {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        return Set(records.compactMap(\.localIdentifier))
    }

    /// 「ローカル localIdentifier → Dropbox path」対応（自動アルバムの重複排除用）。
    public func localToCloudPaths() -> [String: String] {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var map: [String: String] = [:]
        for record in records {
            if let id = record.localIdentifier { map[id] = record.dropboxPath }
        }
        return map
    }

    /// 照合（reconcile）: Dropbox の実ファイル一覧（path_lower → content_hash）に合わせて
    /// 記録を修復する。実在しない/hash が矛盾する記録は削除。
    /// - Parameter listedAt: リモート一覧を**取得し始めた**時刻。これより後に作られた記録は
    ///   この一覧が知り得ないので削除しない（下記）。
    /// 戻り値: (照合に合格した localIdentifier 集合, 削除した記録数)。
    ///
    /// ⚠️ 一覧の取得（list_folder・再帰ページング）には数秒〜数十秒かかる。その間に
    /// バックアップが 1 枚上げて `upsertRecord` すると、そのパスは**古い一覧に無い**ので
    /// 従来実装は削除していた。その後 runner が当該 ID を進捗台帳へ保存すると、次回は
    /// 済み判定で除外され記録が自己修復しない＝共有・オフロード・アルバム集計から
    /// 永久に脱落する（レビュー指摘）。一覧より新しい記録はアップロード時に hash 検証済み
    /// なので、削除せず verified 側に入れる。
    public func reconcile(remote: [String: String],
                          listedAt: Date) -> (verified: Set<String>, removed: Int) {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var removed = 0
        var verifiedIDs: Set<String> = []
        for record in records {
            let path = record.dropboxPath.lowercased()
            if let remoteHash = remote[path],
               record.contentHash == nil || record.contentHash == remoteHash {
                if let id = record.localIdentifier { verifiedIDs.insert(id) }
            } else if record.backedUpAt > listedAt {
                // 一覧の取得後に上がった記録＝この一覧では判定できない。次回の照合に委ねる。
                if let id = record.localIdentifier { verifiedIDs.insert(id) }
            } else {
                modelContext.delete(record)
                removed += 1
            }
        }
        try? modelContext.save()
        return (verifiedIDs, removed)
    }

    /// 全記録の削除（Debug 用・オフロード台帳は対象外）。
    public func deleteAllRecords() {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        records.forEach(modelContext.delete)
        try? modelContext.save()
    }

    /// アルバム集計（記録数・アルバム別インフォ）。Engine の @Observable 状態の材料。
    public func albumSummary() -> (recordCount: Int, albums: [BackupAlbumInfo]) {
        let records = (try? modelContext.fetch(FetchDescriptor<BackupAssetRecord>())) ?? []
        var byAlbum: [String: [BackupAssetRecord]] = [:]
        for record in records {
            for name in record.albums {
                byAlbum[name, default: []].append(record)
            }
        }
        let built = byAlbum.map { name, recs -> BackupAlbumInfo in
            let ids = recs.compactMap { $0.localIdentifier }
            let sorted = recs.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            return BackupAlbumInfo(name: name, photoCount: recs.count,
                                   coverLocalIdentifier: sorted.last?.localIdentifier,
                                   localIdentifiers: ids)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (records.count, built)
    }

    // MARK: - Offload ledger

    /// オフロード実行の記録（upsert）。
    /// - Returns: **永続化できたか**。オフロードは「台帳に記録してから写真を消す」が不変条件で、
    ///   保存失敗（容量不足・SwiftData 障害）を握り潰すと**記録の無い削除**になる（レビュー指摘）。
    @discardableResult
    public func upsertOffloads(_ items: [(localIdentifier: String, dropboxPath: String,
                                          albums: [String], captureDate: Date?,
                                          contentHash: String?)]) -> Bool {
        for item in items {
            let id = item.localIdentifier
            let descriptor = FetchDescriptor<OffloadRecord>(
                predicate: #Predicate { $0.localIdentifier == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                modelContext.delete(existing)
            }
            modelContext.insert(OffloadRecord(localIdentifier: item.localIdentifier,
                                              dropboxPath: item.dropboxPath.lowercased(),
                                              albums: item.albums,
                                              captureDate: item.captureDate,
                                              contentHash: item.contentHash))
        }
        do {
            try modelContext.save()
            return true
        } catch {
            BackupLogger.error("upsertOffloads: save failed — \(error)")
            modelContext.rollback()
            return false
        }
    }

    /// マーカー未送信の台帳エントリ（再送対象）。件数は少ない前提で全件から絞る。
    public func offloadsPendingMarker(limit: Int = 200)
        -> [(localIdentifier: String, dropboxPath: String, albums: [String], captureDate: Date?)] {
        let records = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>(
            predicate: #Predicate { $0.markerUploadedAt == nil },
            sortBy: [SortDescriptor(\.offloadedAt, order: .forward)]))) ?? []
        return records.prefix(limit).map {
            ($0.localIdentifier, $0.dropboxPath, $0.albums, $0.captureDate)
        }
    }

    /// マーカーを書けたエントリに印を付ける（以後の再送対象から外す）。
    public func markOffloadMarkersUploaded(localIdentifiers: [String], at date: Date = Date()) {
        let ids = Set(localIdentifiers)
        guard !ids.isEmpty else { return }
        let all = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        for record in all where ids.contains(record.localIdentifier) {
            record.markerUploadedAt = date
        }
        try? modelContext.save()
    }

    /// 台帳からの削除（復元・ロールバック用）。
    public func removeOffloads(localIdentifiers: [String]) {
        let ids = Set(localIdentifiers)
        let all = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        for record in all where ids.contains(record.localIdentifier) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    /// オフロード台帳の集計（アルバム名 → クラウド代替パス・撮影日昇順）＋総件数。
    public func offloadLedgerSnapshot() -> (byAlbum: [String: [String]], count: Int) {
        let records = (try? modelContext.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        var byAlbum: [String: [(Date?, String)]] = [:]
        for record in records {
            for album in record.albums {
                byAlbum[album, default: []].append((record.captureDate, record.dropboxPath))
            }
        }
        let sorted = byAlbum.mapValues { list in
            list.sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }.map(\.1)
        }
        return (sorted, records.count)
    }
}
