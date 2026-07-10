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
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool)
    /// 既存 SwiftData レコードと新規分をマージした metadata entries を構築する。
    func runnerBuildMetadataEntries(
        merging newEntries: [String: DropboxBackupMetadata.Entry]
    ) -> [String: DropboxBackupMetadata.Entry]
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

    init(
        tokenProvider: AccessTokenProvider,
        uploader: DropboxBackupUploader,
        progressStore: BackupProgressStore,
        uploadLimit: @escaping () -> Int,
        delegate: BackupRunnerDelegate
    ) {
        self.tokenProvider = tokenProvider
        self.uploader = uploader
        self.progressStore = progressStore
        self.uploadLimit = uploadLimit
        self.delegate = delegate
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
        let peopleIndex: [String: [String]] = [:]
        let albumIndex = await Task.detached { buildAlbumIndex() }.value
        let uniqueAlbums = Set(albumIndex.values.flatMap { $0 }).count
        addLog("Index built — albums: \(uniqueAlbums)")
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
        var newEntries: [String: DropboxBackupMetadata.Entry] = [:]

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

            switch await uploader.upload(data: data, to: dropboxPath, token: token) {
            case .uploaded:
                uploadedCount += 1
                trackedIDs.insert(asset.localIdentifier)
                addLog("  ✓ uploaded")

                let people     = peopleIndex[asset.localIdentifier] ?? []
                let albums     = albumIndex[asset.localIdentifier] ?? []
                let isFavorite = asset.isFavorite
                newEntries[dropboxPath.lowercased()] = DropboxBackupMetadata.Entry(
                    people: people,
                    albums: albums,
                    isFavorite: isFavorite,
                    date: asset.creationDate.map { ISO8601DateFormatter().string(from: $0) }
                )
                delegate.runnerSaveRecord(
                    dropboxPath: dropboxPath, asset: asset, filename: filename,
                    people: people, albums: albums, isFavorite: isFavorite
                )
                if uploadedCount % 5 == 0 { progressStore.saveUploadedIDs(trackedIDs) }

            case .alreadyExists:
                addLog("  → already exists on Dropbox (409)")
                trackedIDs.insert(asset.localIdentifier)

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

        // 7. metadata.json を Dropbox へ送信（既存 SwiftData レコードと新規分をマージ）
        if !newEntries.isEmpty {
            setPhase(.uploadingMetadata)
            addLog("Uploading metadata.json (\(newEntries.count) new entries)…")
            let metadata = DropboxBackupMetadata(entries: delegate.runnerBuildMetadataEntries(merging: newEntries))
            let metaPath = folder + BackupEngine.metadataSuffix
            let metaResult = await uploader.uploadMetadata(metadata, to: metaPath, token: token)
            addLog("metadata.json: \(metaResult)")
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
