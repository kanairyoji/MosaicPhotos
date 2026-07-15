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
}

// MARK: - Runner

/// バックアップ 1 回分の実行ユニット（権限取得→差分算出→アップロードループ→metadata 送信）。
/// `BackupEngine` から分離し、engine は状態公開と起動/キャンセルの薄いコーディネータに絞る。
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

    // MARK: - Backup main loop

    /// バックアップ本体。戻り値は「完走した（＝アルバム一覧の再読込が必要）」かどうか。
    func run(folder: String) async -> Bool {
        addLog("Starting backup → \(folder)")

        // 1. 写真ライブラリのアクセス権を取得
        let authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        addLog("Photo library auth: \(authStatus.debugDescription)")
        guard authStatus == .authorized || authStatus == .limited else {
            fail("Photo library access denied. Allow access in Settings → Privacy → Photos.")
            return false
        }
        guard !Task.isCancelled else { setPhase(.cancelled); return false }

        // 2. People + アルバム インデックスをバックグラウンドで構築
        // ⚠️ buildAlbumIndex はファイル末尾のトップレベル関数である必要がある。
        // インスタンスメソッドとして定義すると Task.detached クロージャ内でコンパイラが
        // self のインスタンスメソッドを優先して解決し、@MainActor 型を Task.detached に
        // 渡せないコンパイルエラーになる（過去に発生）。
        // 旧 People インデックス（写真アプリの People アルバム走査＝subtype-1000）は非公開化で
        // **常に空**だったため撤去。metadata の people は空を維持する（互換のためキーは残す）。
        setPhase(.buildingPeopleIndex)
        addLog("Building Album index…")
        // 人物名はアプリの顔クラスタ（PeopleEngine・ユーザー命名）から取得する（v2・ADR-38）。
        // 旧 People インデックス（subtype-1000）は常に空だったため撤去済み。
        let peopleIndex: [String: [String]] = await peopleNamesProvider?() ?? [:]
        let albumIndex = await Task.detached { buildAlbumIndex() }.value
        let albumIDIndex = await Task.detached { buildAlbumIDIndex() }.value
        let uniqueAlbums = Set(albumIndex.values.flatMap { $0 }).count
        addLog("Index built — albums: \(uniqueAlbums), people entries: \(peopleIndex.count)")
        guard !Task.isCancelled else { setPhase(.cancelled); return false }

        // 3. 全画像アセットを日付昇順で取得
        setPhase(.fetchingAssets)
        let fetchOpts = PHFetchOptions()
        fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: fetchOpts)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        addLog("Total assets: \(assets.count)")
        guard !Task.isCancelled else { setPhase(.cancelled); return false }

        // 4. 既アップロード済みをスキップ（差分算出は BackupPlanning に集約・テスト可能）。
        //    上限は設定（uploadLimit）優先。> 0 で 1 回のアップロード上限を適用（0 = 無制限）。
        let limit = uploadLimit()
        let doneIDs = progressStore.loadUploadedIDs()
        let plan = BackupPlanning.pendingUploads(
            allIdentifiers: assets.map(\.localIdentifier),
            alreadyUploaded: doneIDs,
            limit: limit
        )
        let pendingSet = Set(plan.pending)
        let pending = assets.filter { pendingSet.contains($0.localIdentifier) }
        let alreadySkipped = plan.skipped
        addLog("Pending: \(pending.count) (already backed up: \(alreadySkipped)\(limit > 0 ? ", limit \(limit)" : ""))")

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
        let token: String
        do {
            token = try await tokenProvider.freshAccessToken()
            addLog("Token OK")
        } catch {
            fail("Authentication failed: \(error.localizedDescription)")
            return false
        }

        // 6. 1 枚ずつアップロード
        var uploadedCount = 0
        var skippedCount  = 0
        var trackedIDs    = doneIDs
        var newEntries: [BackupMetadataPlanning.NewEntry] = []

        for (i, asset) in pending.enumerated() {
            guard !Task.isCancelled else { setPhase(.cancelled); return false }

            // 電源＋回線ポリシー：満たさない間は一時停止し、復帰で再開する
            //（充電中かつ低電力OFF・既定で Wi-Fi のみ）。
            if !backgroundUploadAllowed {
                addLog("Paused — waiting for power / Wi-Fi")
                while !backgroundUploadAllowed && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                }
                guard !Task.isCancelled else { setPhase(.cancelled); return false }
                addLog("Resumed")
            }

            // ファイルデータを取得
            let fetchResult = await BackupAssetReader.read(asset: asset, fallback: "photo_\(i + 1).jpg")
            switch fetchResult {
            case .skipped(let filename, let reason):
                addLog("[\(i+1)/\(pending.count)] SKIP \(filename): \(reason)")
                skippedCount += 1
                continue
            case .success:
                break
            }
            guard case .success(let data, let filename) = fetchResult else { continue }

            setPhase(.uploading(current: i + 1, total: pending.count, filename: filename))
            guard !Task.isCancelled else { setPhase(.cancelled); return false }

            let dropboxPath = folder + "/" + filename
            addLog("[\(i+1)/\(pending.count)] \(filename) (\(data.count) bytes) → \(dropboxPath)")

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
                uploadedCount += 1
                trackedIDs.insert(asset.localIdentifier)
                addLog("  ✓ uploaded (hash verified)\(savedPath == dropboxPath.lowercased() ? "" : " as \(savedPath)")")

                let people     = peopleIndex[asset.localIdentifier] ?? []
                let albums     = albumIndex[asset.localIdentifier] ?? []
                let isFavorite = asset.isFavorite
                // v2（ADR-38）: 端末を削除すると再生成できない情報を漏れなく保全する。
                // パスは実際に保存された savedPath（autorename 時は要求と異なる）。
                newEntries.append(BackupMetadataPlanning.NewEntry(
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
                        caption: captionsByID[asset.localIdentifier]
                    )))
                delegate.runnerSaveRecord(
                    dropboxPath: savedPath, asset: asset, filename: filename,
                    people: people, albums: albums, isFavorite: isFavorite,
                    contentHash: hash
                )
                if uploadedCount % 5 == 0 { progressStore.saveUploadedIDs(trackedIDs) }

            case .hashMismatch(let expected, let actual):
                // HTTP 200 でも中身の検証に失敗＝壊れて保存された疑い。**絶対に「済み」にしない**
                //（次回実行で再アップロードされる）。連続するなら回線/API の異常なので実行を止める。
                addLog("  ✗ content hash mismatch — expected \(expected.prefix(12))…, got \((actual ?? "nil").prefix(12))…")
                fail("Content hash mismatch uploading \"\(filename)\" — not marked as backed up; will retry next run")
                progressStore.saveUploadedIDs(trackedIDs)
                return false

            case .alreadyExists:
                // autorename=true の再試行後には発生しない想定（保険）。
                addLog("  ✗ unexpected 409 after autorename")
                fail("Unexpected conflict uploading \"\(filename)\"")
                progressStore.saveUploadedIDs(trackedIDs)
                return false

            case .error(let code, let body):
                let summary = BackupPlanning.dropboxErrorSummary(from: body)
                addLog("  ✗ HTTP \(code): \(summary)")
                fail("HTTP \(code) uploading \"\(filename)\"\n\(summary)")
                progressStore.saveUploadedIDs(trackedIDs)
                return false

            case .networkError(let msg):
                addLog("  ✗ network error: \(msg)")
                fail("Network error uploading \"\(filename)\": \(msg)")
                progressStore.saveUploadedIDs(trackedIDs)
                return false
            }
        }

        progressStore.saveUploadedIDs(trackedIDs)

        // 7. メタデータ v2（ADR-38）: 触った撮影月シャードだけをマージ更新し、カタログを書く。
        //    v1 metadata.json は凍結（読み込み側が v1 ベース＋v2 上書きで統合する）。
        if !newEntries.isEmpty {
            setPhase(.uploadingMetadata)
            let byShard = BackupMetadataPlanning.groupedByShard(newEntries)
            addLog("Uploading metadata v2 (\(newEntries.count) entries → \(byShard.count) shard(s))…")
            for (shard, entries) in byShard.sorted(by: { $0.key < $1.key }) {
                let shardPath = folder + BackupMetadataV2.shardSuffix(shard)
                let existing = await uploader.download(path: shardPath, token: token)
                let merged = BackupMetadataPlanning.mergedShard(existing: existing, adding: entries)
                let result = await uploader.uploadJSON(merged, to: shardPath, token: token)
                addLog("  meta/\(shard).json (+\(entries.count) → \(merged.entries.count)): \(result)")
            }
            let catalogPath = folder + BackupMetadataV2.catalogSuffix
            let existingCatalog = await uploader.download(path: catalogPath, token: token)
            let albumNames = Array(Set(albumIndex.values.flatMap { $0 })).sorted()
            let peopleNames = Array(Set(peopleIndex.values.flatMap { $0 })).sorted()
            let catalog = BackupMetadataPlanning.updatedCatalog(
                existing: existingCatalog, touchedShards: Array(byShard.keys),
                albums: albumNames, people: peopleNames, albumIDs: albumIDIndex)
            let catResult = await uploader.uploadJSON(catalog, to: catalogPath, token: token)
            addLog("  catalog.json (shards=\(catalog.shards.count)): \(catResult)")
        }

        let totalSkipped = alreadySkipped + skippedCount + (pending.count - uploadedCount - skippedCount)
        addLog("Done — uploaded: \(uploadedCount), skipped: \(totalSkipped)")
        setPhase(.completed(uploaded: uploadedCount, skipped: totalSkipped))
        // バックアップ完了後のアルバム一覧更新（loadAlbums）は engine 側で行う（戻り値 true で通知）。
        return true
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
