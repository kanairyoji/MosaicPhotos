import Foundation
import Photos
import SwiftData
import DropboxCore
import MosaicSupport

// MARK: - Delegate

/// `BackupRunner` が進捗・ログ・レコード保存を通知する先（実体は `BackupEngine`）。
/// @Observable な phase / log の UI 反映は MainActor（engine）側に留め、runner はここへ委譲する。
@MainActor
protocol BackupRunnerDelegate: AnyObject {
    /// フェーズ更新（engine の @Observable phase に反映される）。
    func runnerSetPhase(_ phase: BackupEngine.Phase)
    /// 実行ログ 1 行の追記。
    func runnerLog(_ message: String)
    /// アップロード成功 1 件の SwiftData レコード保存（BackupEngine+Store）。
    /// `contentHash` は検証済みの Dropbox content_hash（オフロード前検証の照合キー）。
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?)
    /// SwiftData 記録にある「実際にアップロード済み」の localIdentifier 集合。
    /// UserDefaults の台帳が消えても（Clear upload progress・再インストール等）、
    /// 記録から差分判定を自己修復し**二重アップロードを防ぐ**（実障害: 台帳クリア＋
    /// 端末フォルダ移行の組み合わせで同一写真がルートと端末フォルダに重複した）。
    func runnerRecordedLocalIdentifiers() async -> Set<String>
}

// MARK: - Runner

/// バックアップ 1 回分の実行ユニット。`run(folder:)` はフェーズごとのメソッドを順に呼ぶ
/// オーケストレータに絞り（B6 リファクタリング・挙動不変）、各フェーズは
/// 権限 → 索引構築 → 差分算出 → アップロードループ → メタデータ書き込み に分かれる。
/// 進捗トラッキング（uploaded/skipped・アップロード済み ID の永続化）はここが持ち、
/// UI へ見せる状態は `BackupRunnerDelegate` 経由で engine に反映する。
@MainActor
final class BackupRunner {

    private let tokenProvider: AccessTokenProvider
    private let uploader: DropboxBackupUploader
    private let progressStore: BackupProgressStore
    /// 実効アップロード上限。設定変更を実行直前に読むためクロージャで受ける（0 以下で無制限）。
    private let uploadLimit: () -> Int
    /// 通知先。runner は engine の Task ローカルにのみ生存するため強参照でも循環しない。
    private let delegate: BackupRunnerDelegate
    /// 人物名（localIdentifier → 命名済み顔クラスタのフルネーム）。アプリが PeopleEngine を結線する。
    /// ユーザー入力（命名）は端末を削除すると再生成できないため metadata に保全する（ADR-38）。
    private let peopleNamesProvider: (@Sendable () async -> [String: [String]])?
    /// VLM キャプション（localIdentifier → 説明文）。アプリが TagStore を結線する。
    private let captionsProvider: (@Sendable ([String]) async -> [String: String])?

    init(
        tokenProvider: AccessTokenProvider,
        uploader: DropboxBackupUploader,
        progressStore: BackupProgressStore,
        uploadLimit: @escaping () -> Int,
        delegate: BackupRunnerDelegate,
        peopleNamesProvider: (@Sendable () async -> [String: [String]])? = nil,
        captionsProvider: (@Sendable ([String]) async -> [String: String])? = nil
    ) {
        self.tokenProvider = tokenProvider
        self.uploader = uploader
        self.progressStore = progressStore
        self.uploadLimit = uploadLimit
        self.delegate = delegate
        self.peopleNamesProvider = peopleNamesProvider
        self.captionsProvider = captionsProvider
    }

    /// 背景アップロードを行ってよいか（電源＋回線ポリシー）。アップロードループの一時停止判定に使う。
    private var backgroundUploadAllowed: Bool {
        PowerStateMonitor.shared.backgroundAllowed() && NetworkStateMonitor.shared.networkAllowed()
    }

    // MARK: - フェーズ間で受け渡す値

    /// フェーズ 2 の成果物（端末側の索引）。
    private struct Indexes {
        let people: [String: [String]]      // localIdentifier → 人物名（顔クラスタ・ユーザー命名）
        let albums: [String: [String]]      // localIdentifier → 所属アルバム名
        let albumIDs: [String: String]      // アルバム名 → PHAssetCollection.localIdentifier
    }

    /// アップロードループの集計。
    private struct UploadTally {
        var uploaded = 0
        var skippedRead = 0
        var trackedIDs: Set<String>
        var newEntries: [BackupMetadataPlanning.NewEntry] = []
    }

    /// 1 枚のアップロード結果。
    private enum ItemOutcome {
        case done            // 成功（tally 更新済み）
        case skipped         // 読み込みスキップ（続行）
        case fatal           // 実行を止める（fail 済み・進捗保存済み）
    }

    // MARK: - Backup main loop（オーケストレータ）

    /// バックアップ本体。戻り値は「完走した（＝アルバム一覧の再読込が必要）」かどうか。
    func run(folder: String) async -> Bool {
        addLog("Starting backup → \(folder)")

        // 1. 写真ライブラリのアクセス権
        guard await requestPhotoAccess() else { return false }
        guard !Task.isCancelled else { setPhase(.cancelled); return false }

        // 2. 索引構築（人物＝顔クラスタ・アルバム・アルバム ID）
        let indexes = await buildIndexes()
        guard !Task.isCancelled else { setPhase(.cancelled); return false }

        // 3-4. 全アセット取得 → 差分算出（済み＝台帳∪記録・上限適用）
        let assets = fetchAssetsSorted()
        guard !Task.isCancelled else { setPhase(.cancelled); return false }
        let (pending, alreadySkipped, doneIDs) = await computePending(assets: assets)
        guard !pending.isEmpty else {
            addLog("Nothing to upload.")
            setPhase(.completed(uploaded: 0, skipped: alreadySkipped))
            return false
        }

        // 4.5 アップロード対象のキャプションを一括取得（アプリ生成・小さいテキストのみ）。
        let captionsByID: [String: String] =
            await captionsProvider?(pending.map(\.localIdentifier)) ?? [:]

        // 5. Dropbox 認証
        addLog("Fetching Dropbox access token…")
        guard let token = try? await tokenProvider.freshAccessToken() else {
            fail("Authentication failed")
            return false
        }
        addLog("Token OK")

        // 6. 1 枚ずつアップロード（検証つき・電源/回線ポーズ・キャンセル対応）
        var tally = UploadTally(trackedIDs: doneIDs)
        for (i, asset) in pending.enumerated() {
            guard !Task.isCancelled else { setPhase(.cancelled); return false }
            guard await waitUntilUploadAllowed() else { setPhase(.cancelled); return false }
            switch await uploadOne(asset: asset, index: i, total: pending.count,
                                   folder: folder, token: token,
                                   indexes: indexes, captions: captionsByID, tally: &tally) {
            case .done, .skipped: continue
            case .fatal: return false
            }
        }
        progressStore.saveUploadedIDs(tally.trackedIDs)

        // 7. メタデータ v2（触った撮影月シャード＋カタログ）
        await writeMetadata(newEntries: tally.newEntries, indexes: indexes,
                            folder: folder, token: token)

        let totalSkipped = alreadySkipped + tally.skippedRead
            + (pending.count - tally.uploaded - tally.skippedRead)
        addLog("Done — uploaded: \(tally.uploaded), skipped: \(totalSkipped)")
        setPhase(.completed(uploaded: tally.uploaded, skipped: totalSkipped))
        // バックアップ完了後のアルバム一覧更新（loadAlbums）は engine 側で行う（戻り値 true で通知）。
        return true
    }

    // MARK: - フェーズ 1: 権限

    private func requestPhotoAccess() async -> Bool {
        let authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        addLog("Photo library auth: \(authStatus.debugDescription)")
        guard authStatus == .authorized || authStatus == .limited else {
            fail("Photo library access denied. Allow access in Settings → Privacy → Photos.")
            return false
        }
        return true
    }

    // MARK: - フェーズ 2: 索引構築

    /// 人物（顔クラスタ・ADR-38）とアルバム所属・アルバム ID（ADR-39/41）の索引を作る。
    /// ⚠️ buildAlbumIndex はトップレベル関数である必要がある（インスタンスメソッドだと
    /// Task.detached 内で @MainActor の self を捕捉しようとしてコンパイルエラー＝過去に発生）。
    private func buildIndexes() async -> Indexes {
        setPhase(.buildingPeopleIndex)
        addLog("Building Album index…")
        let people: [String: [String]] = await peopleNamesProvider?() ?? [:]
        let albums = await Task.detached { buildAlbumIndex() }.value
        let albumIDs = await Task.detached { buildAlbumIDIndex() }.value
        let uniqueAlbums = Set(albums.values.flatMap { $0 }).count
        addLog("Index built — albums: \(uniqueAlbums), people entries: \(people.count)")
        return Indexes(people: people, albums: albums, albumIDs: albumIDs)
    }

    // MARK: - フェーズ 3-4: 全アセット取得と差分算出

    private func fetchAssetsSorted() -> [PHAsset] {
        setPhase(.fetchingAssets)
        let fetchOpts = PHFetchOptions()
        fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: fetchOpts)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        addLog("Total assets: \(assets.count)")
        return assets
    }

    /// 済み判定は「UserDefaults 台帳 ∪ SwiftData 記録」。記録は実アップロード成功時のみ
    /// 追加される確かな出典で、台帳が消えた場合の自己修復を担う（重複アップロード防止）。
    private func computePending(assets: [PHAsset]) async -> (pending: [PHAsset], alreadySkipped: Int, doneIDs: Set<String>) {
        let limit = uploadLimit()
        let ledgerIDs = progressStore.loadUploadedIDs()
        let recordIDs = await delegate.runnerRecordedLocalIdentifiers()
        let doneIDs = ledgerIDs.union(recordIDs)
        if doneIDs.count > ledgerIDs.count {
            addLog("Restored \(doneIDs.count - ledgerIDs.count) backed-up ID(s) from records")
            progressStore.saveUploadedIDs(doneIDs)   // 台帳側も修復
        }
        let plan = BackupPlanning.pendingUploads(
            allIdentifiers: assets.map(\.localIdentifier),
            alreadyUploaded: doneIDs,
            limit: limit
        )
        let pendingSet = Set(plan.pending)
        let pending = assets.filter { pendingSet.contains($0.localIdentifier) }
        addLog("Pending: \(pending.count) (already backed up: \(plan.skipped)\(limit > 0 ? ", limit \(limit)" : ""))")
        return (pending, plan.skipped, doneIDs)
    }

    // MARK: - フェーズ 6: アップロードループ

    /// 電源＋回線ポリシーを満たすまで待つ（キャンセルで false）。
    private func waitUntilUploadAllowed() async -> Bool {
        guard !backgroundUploadAllowed else { return true }
        addLog("Paused — waiting for power / Wi-Fi")
        while !backgroundUploadAllowed && !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
        }
        guard !Task.isCancelled else { return false }
        addLog("Resumed")
        return true
    }

    /// 1 枚のアップロード（読み込み → 検証つきアップロード → 409 の hash 照合 → 記録）。
    private func uploadOne(asset: PHAsset, index i: Int, total: Int,
                           folder: String, token: String,
                           indexes: Indexes, captions: [String: String],
                           tally: inout UploadTally) async -> ItemOutcome {
        // フォールバック名は localIdentifier 由来の安定名（旧: 実行内インデックス名は
        // 実行ごとに 1 から振り直され、別の写真が同名になって 409 を誘発する設計バグだった）。
        let stableFallback = "photo_" + asset.localIdentifier.prefix(8)
            .replacingOccurrences(of: "/", with: "-") + ".jpg"
        let fetchResult = await BackupAssetReader.read(asset: asset, fallback: stableFallback)
        guard case .success(let data, let filename) = fetchResult else {
            if case .skipped(let filename, let reason) = fetchResult {
                addLog("[\(i+1)/\(total)] SKIP \(filename): \(reason)")
                tally.skippedRead += 1
            }
            return .skipped
        }

        setPhase(.uploading(current: i + 1, total: total, filename: filename))
        guard !Task.isCancelled else { setPhase(.cancelled); return .fatal }

        let dropboxPath = folder + "/" + filename
        addLog("[\(i+1)/\(total)] \(filename) (\(data.count) bytes) → \(dropboxPath)")

        // ADR-40: ローカルで content_hash を計算し、応答の hash と一致して初めて「済み」にする。
        let localHash = DropboxContentHash.hash(of: data)
        var result = await uploader.upload(data: data, to: dropboxPath, token: token,
                                           expectedHash: localHash)
        if result == .alreadyExists {
            // 409（同パスに既存）: 同一内容か **hash で確認**する。旧実装は無確認で「済み」
            // 扱いにしており、同名の別写真が「バックアップ済み」と誤記録される＝オフロードで
            // 永久喪失し得る欠陥だった。不一致なら autorename で別名アップロードする。
            let remote = await uploader.getMetadata(path: dropboxPath, token: token)
            if let remote, remote.contentHash == localHash {
                addLog("  → already exists with identical content (hash verified)")
                result = .uploaded(path: dropboxPath.lowercased(), contentHash: localHash)
            } else {
                addLog("  → name collision with different content — retrying with autorename")
                result = await uploader.upload(data: data, to: dropboxPath, token: token,
                                               expectedHash: localHash, autorename: true)
            }
        }

        switch result {
        case .uploaded(let savedPath, let hash):
            tally.uploaded += 1
            tally.trackedIDs.insert(asset.localIdentifier)
            addLog("  ✓ uploaded (hash verified)\(savedPath == dropboxPath.lowercased() ? "" : " as \(savedPath)")")
            let people     = indexes.people[asset.localIdentifier] ?? []
            let albums     = indexes.albums[asset.localIdentifier] ?? []
            let isFavorite = asset.isFavorite
            // v2（ADR-38）: 端末を削除すると再生成できない情報を漏れなく保全する。
            // パスは実際に保存された savedPath（autorename 時は要求と異なる）。
            tally.newEntries.append(BackupMetadataPlanning.NewEntry(
                path: savedPath,
                date: asset.creationDate,
                entry: DropboxBackupMetadata.Entry(
                    people: people,
                    albums: albums,
                    isFavorite: isFavorite,
                    date: asset.creationDate.map { ISO8601DateFormatter().string(from: $0) },
                    contentHash: hash,
                    localIdentifier: asset.localIdentifier,
                    latitude: asset.location?.coordinate.latitude,
                    longitude: asset.location?.coordinate.longitude,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    caption: captions[asset.localIdentifier]
                )))
            delegate.runnerSaveRecord(
                dropboxPath: savedPath, asset: asset, filename: filename,
                people: people, albums: albums, isFavorite: isFavorite,
                contentHash: hash
            )
            if tally.uploaded % 5 == 0 { progressStore.saveUploadedIDs(tally.trackedIDs) }
            return .done

        case .hashMismatch(let expected, let actual):
            // HTTP 200 でも中身の検証に失敗＝壊れて保存された疑い。**絶対に「済み」にしない**
            //（次回実行で再アップロードされる）。連続するなら回線/API の異常なので実行を止める。
            addLog("  ✗ content hash mismatch — expected \(expected.prefix(12))…, got \((actual ?? "nil").prefix(12))…")
            fail("Content hash mismatch uploading \"\(filename)\" — not marked as backed up; will retry next run")
            progressStore.saveUploadedIDs(tally.trackedIDs)
            return .fatal

        case .alreadyExists:
            // autorename=true の再試行後には発生しない想定（保険）。
            addLog("  ✗ unexpected 409 after autorename")
            fail("Unexpected conflict uploading \"\(filename)\"")
            progressStore.saveUploadedIDs(tally.trackedIDs)
            return .fatal

        case .error(let code, let body):
            let summary = BackupPlanning.dropboxErrorSummary(from: body)
            addLog("  ✗ HTTP \(code): \(summary)")
            fail("HTTP \(code) uploading \"\(filename)\"\n\(summary)")
            progressStore.saveUploadedIDs(tally.trackedIDs)
            return .fatal

        case .networkError(let msg):
            addLog("  ✗ network error: \(msg)")
            fail("Network error uploading \"\(filename)\": \(msg)")
            progressStore.saveUploadedIDs(tally.trackedIDs)
            return .fatal
        }
    }

    // MARK: - フェーズ 7: メタデータ v2 書き込み

    /// 触った撮影月シャードだけをマージ更新し、カタログを書く（ADR-38）。
    /// v1 metadata.json は凍結（読み込み側が v1 ベース＋v2 上書きで統合する）。
    /// シャードの download→merge→upload は `MetadataShardWriter` に集約（B3）。
    private func writeMetadata(newEntries: [BackupMetadataPlanning.NewEntry],
                               indexes: Indexes, folder: String, token: String) async {
        guard !newEntries.isEmpty else { return }
        setPhase(.uploadingMetadata)
        let byShard = BackupMetadataPlanning.groupedByShard(newEntries)
        addLog("Uploading metadata v2 (\(newEntries.count) entries → \(byShard.count) shard(s))…")
        let writer = MetadataShardWriter(uploader: uploader, token: token)
        let touched = await writer.applyEntries(byShard: byShard, folder: folder) { line in
            self.addLog(line)
        }
        let catalogPath = folder + BackupMetadataV2.catalogSuffix
        let existingCatalog = await uploader.download(path: catalogPath, token: token)
        let albumNames = Array(Set(indexes.albums.values.flatMap { $0 })).sorted()
        let peopleNames = Array(Set(indexes.people.values.flatMap { $0 })).sorted()
        let catalog = BackupMetadataPlanning.updatedCatalog(
            existing: existingCatalog, touchedShards: touched,
            albums: albumNames, people: peopleNames, albumIDs: indexes.albumIDs,
            deviceID: BackupDeviceIdentity.currentID(),
            deviceName: BackupDeviceIdentity.currentDisplayName())
        let catResult = await uploader.uploadJSON(catalog, to: catalogPath, token: token)
        addLog("  catalog.json (shards=\(catalog.shards.count)): \(catResult)")
    }

    // MARK: - Helpers

    private func setPhase(_ phase: BackupEngine.Phase) {
        delegate.runnerSetPhase(phase)
    }

    private func addLog(_ message: String) {
        delegate.runnerLog(message)
    }

    private func fail(_ message: String) {
        addLog("FAILED: \(message)")
        setPhase(.failed(message))
    }
}
