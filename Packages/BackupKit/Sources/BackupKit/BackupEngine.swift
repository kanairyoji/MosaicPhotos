import Foundation
import Photos
import SwiftData
import DropboxCore
import MosaicSupport

// MARK: - Log entry

public struct BackupLogEntry: Identifiable, Sendable {
    public let id = UUID()
    public let time: String
    public let message: String

    init(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        self.time    = f.string(from: Date())
        self.message = message
    }
}

// MARK: - Engine

/// ローカル写真を Dropbox へバックアップするエンジン。
@MainActor
@Observable
public final class BackupEngine {

    public private(set) var phase: Phase = .idle {
        didSet { DropboxActivityMonitor.shared.setBackupActive(phase.isUploadingNetwork) }
    }
    /// 直近のバックアップ実行ログ。Debug セクションで表示する。
    public private(set) var log: [BackupLogEntry] = []
    /// BackupAssetRecord から集計したアルバム一覧。
    public internal(set) var albumInfos: [BackupAlbumInfo] = []
    /// SwiftData に保存済みの BackupAssetRecord 総数。0 = バックアップ未実行 or 保存失敗。
    public internal(set) var recordCount: Int = 0
    /// loadAlbums() が完了したかどうか。ロード中と「空」を区別するために使う。
    public internal(set) var isAlbumsLoaded: Bool = false

    // SwiftData レコード/アルバム永続化は BackupEngine+Store.swift（extension）に分離しているため、
    // そこから参照する modelContext / addLog / 上記の集計状態は internal にしている。
    @ObservationIgnored private let tokenProvider: AccessTokenProvider
    @ObservationIgnored private let uploader: DropboxBackupUploader
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    @ObservationIgnored var modelContext: ModelContext?

    // MARK: - Phase

    public enum Phase: Equatable {
        case idle
        case requestingPermission
        case buildingPeopleIndex
        case fetchingAssets
        case uploading(current: Int, total: Int, filename: String)
        case uploadingMetadata
        case completed(uploaded: Int, skipped: Int)
        case failed(String)
        case cancelled

        /// 実ネットワークアップロード中か（写真/メタデータ送信）。アクティビティ計測用。
        var isUploadingNetwork: Bool {
            switch self {
            case .uploading, .uploadingMetadata: return true
            default: return false
            }
        }
    }

    public var isRunning: Bool {
        switch phase {
        case .requestingPermission, .buildingPeopleIndex, .fetchingAssets,
             .uploading, .uploadingMetadata: return true
        default: return false
        }
    }

    // MARK: - Init

    /// アップロード上限の既定（テスト・フォールバック用）。0 にすると全件。
    /// 実際に使う値は設定（`BackupSettingsKeys.uploadLimit`）が優先される。
    public var debugUploadLimit = 10

    /// 実効アップロード上限。設定キーが存在すればその値、無ければ `debugUploadLimit`。
    var effectiveUploadLimit: Int {
        UserDefaults.standard.object(forKey: BackupSettingsKeys.uploadLimit) == nil
            ? debugUploadLimit
            : UserDefaults.standard.integer(forKey: BackupSettingsKeys.uploadLimit)
    }

    /// バックアップ進捗として保存済みのローカル ID 数（設定表示用）。
    public var uploadedIDCount: Int { loadUploadedIDs().count }

    /// metadata.json のパス接尾辞（設定の Debug 表示用）。
    public static var metadataPathSuffix: String { metadataSuffix }

    /// バックアップ進捗（アップロード済み ID 一覧）を消去する。次回は全件再判定になる（Debug 用）。
    public func clearUploadProgress() {
        saveUploadedIDs([])
    }

    public init(auth: DropboxAuthService, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = auth
        self.uploader = DropboxBackupUploader(httpClient: httpClient)
        // ⚠️ 名前を明示して "BackupKit.store" を使う（名前なしは "default.store" になり
        // DropboxCacheStore と衝突＝過去にクラッシュ）。壊れた/非互換ストアは削除して作り直す（自己修復）。
        modelContext = ModelContext(Self.makeResilientContainer())
    }

    /// 名前付き永続コンテナを作る。失敗時は store ファイルを削除して再構築し、それでも駄目なら
    /// インメモリへ。SwiftData が trap せず必ず ModelContainer を返し、起動時クラッシュを防ぐ
    /// （バックアップ記録は再構築されるが、Dropbox 上の実ファイルは無事）。
    private static func makeResilientContainer() -> ModelContainer {
        let schema = Schema([BackupAssetRecord.self])
        let config = ModelConfiguration("BackupKit", schema: schema)
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        BackupLogger.error("BackupEngine: 'BackupKit' store open failed; deleting and rebuilding.")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
        }
        if let container = try? ModelContainer(for: schema, configurations: [config]) { return container }
        BackupLogger.error("BackupEngine: 'BackupKit' store still failing; using in-memory store.")
        let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return (try? ModelContainer(for: schema, configurations: [memory])) ?? (try! ModelContainer(for: schema))
    }

    // MARK: - Public API

    public func start(folder: String) {
        guard !isRunning else { return }
        log.removeAll()
        phase = .requestingPermission
        backupTask = Task { [weak self] in
            guard let self else { return }
            await self.run(folder: folder)
            self.backupTask = nil
        }
    }

    public func cancel() {
        backupTask?.cancel()
        backupTask = nil
        if isRunning {
            addLog("Cancelled by user.")
            phase = .cancelled
        }
    }

    // MARK: - Logging

    func addLog(_ message: String) {
        log.append(BackupLogEntry(message))
    }

    // MARK: - Backup main loop

    private func run(folder: String) async {
        addLog("Starting backup → \(folder)")

        // 1. 写真ライブラリのアクセス権を取得
        let authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        addLog("Photo library auth: \(authStatus.debugDescription)")
        guard authStatus == .authorized || authStatus == .limited else {
            fail("Photo library access denied. Allow access in Settings → Privacy → Photos.")
            return
        }
        guard !Task.isCancelled else { phase = .cancelled; return }

        // 2. People + アルバム インデックスをバックグラウンドで構築
        // ⚠️ buildPeopleIndex / buildAlbumIndex はファイル末尾のトップレベル関数である必要がある。
        // インスタンスメソッドとして定義すると Task.detached クロージャ内でコンパイラが
        // self のインスタンスメソッドを優先して解決し、@MainActor 型を Task.detached に
        // 渡せないコンパイルエラーになる（過去に発生）。
        phase = .buildingPeopleIndex
        addLog("Building People / Album index…")
        let (peopleIndex, albumIndex) = await Task.detached {
            (buildPeopleIndex(), buildAlbumIndex())
        }.value
        let uniquePeople = Set(peopleIndex.values.flatMap { $0 }).count
        let uniqueAlbums = Set(albumIndex.values.flatMap { $0 }).count
        addLog("Index built — people: \(uniquePeople), albums: \(uniqueAlbums)")
        guard !Task.isCancelled else { phase = .cancelled; return }

        // 3. 全画像アセットを日付昇順で取得
        phase = .fetchingAssets
        let fetchOpts = PHFetchOptions()
        fetchOpts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: fetchOpts)
        var assets: [PHAsset] = []
        result.enumerateObjects { a, _, _ in assets.append(a) }
        addLog("Total assets: \(assets.count)")
        guard !Task.isCancelled else { phase = .cancelled; return }

        // 4. 既アップロード済みをスキップ（差分算出は BackupPlanning に集約・テスト可能）。
        //    上限は設定（uploadLimit）優先。> 0 で 1 回のアップロード上限を適用（0 = 無制限）。
        let limit = effectiveUploadLimit
        let doneIDs = loadUploadedIDs()
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
            phase = .completed(uploaded: 0, skipped: alreadySkipped)
            return
        }

        // 5. Dropbox 認証
        addLog("Fetching Dropbox access token…")
        let token: String
        do {
            token = try await tokenProvider.freshAccessToken()
            addLog("Token OK")
        } catch {
            fail("Authentication failed: \(error.localizedDescription)")
            return
        }

        // 6. 1 枚ずつアップロード
        var uploadedCount = 0
        var skippedCount  = 0
        var trackedIDs    = doneIDs
        var newEntries: [String: DropboxBackupMetadata.Entry] = [:]

        for (i, asset) in pending.enumerated() {
            guard !Task.isCancelled else { phase = .cancelled; return }

            // 電源ポリシー：充電中（かつ低電力 OFF）以外は一時停止し、電源復帰で再開する。
            if !PowerStateMonitor.shared.backgroundAllowed() {
                addLog("Paused — waiting for power (charging + Low Power off)")
                while !PowerStateMonitor.shared.backgroundAllowed() && !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                }
                guard !Task.isCancelled else { phase = .cancelled; return }
                addLog("Resumed (on power)")
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

            phase = .uploading(current: i + 1, total: pending.count, filename: filename)
            guard !Task.isCancelled else { phase = .cancelled; return }

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
                saveRecord(
                    dropboxPath: dropboxPath, asset: asset, filename: filename,
                    people: people, albums: albums, isFavorite: isFavorite
                )
                if uploadedCount % 5 == 0 { saveUploadedIDs(trackedIDs) }

            case .alreadyExists:
                addLog("  → already exists on Dropbox (409)")
                trackedIDs.insert(asset.localIdentifier)

            case .error(let code, let body):
                let summary = BackupPlanning.dropboxErrorSummary(from: body)
                addLog("  ✗ HTTP \(code): \(summary)")
                fail("HTTP \(code) uploading \"\(filename)\"\n\(summary)")
                saveUploadedIDs(trackedIDs)
                return

            case .networkError(let msg):
                addLog("  ✗ network error: \(msg)")
                fail("Network error uploading \"\(filename)\": \(msg)")
                saveUploadedIDs(trackedIDs)
                return
            }
        }

        saveUploadedIDs(trackedIDs)

        // 7. metadata.json を Dropbox へ送信（既存 SwiftData レコードと新規分をマージ）
        if !newEntries.isEmpty {
            phase = .uploadingMetadata
            addLog("Uploading metadata.json (\(newEntries.count) new entries)…")
            let metadata = DropboxBackupMetadata(entries: buildMetadataEntries(merging: newEntries))
            let metaPath = folder + Self.metadataSuffix
            let metaResult = await uploader.uploadMetadata(metadata, to: metaPath, token: token)
            addLog("metadata.json: \(metaResult)")
        }

        let totalSkipped = alreadySkipped + skippedCount + (pending.count - uploadedCount - skippedCount)
        addLog("Done — uploaded: \(uploadedCount), skipped: \(totalSkipped)")
        phase = .completed(uploaded: uploadedCount, skipped: totalSkipped)
        // バックアップ完了後にアルバム一覧を更新する
        await loadAlbums()
    }

    // MARK: - Metadata

    static let metadataSuffix = "/.mosaic/metadata.json"

    // MARK: - Progress persistence

    private static let uploadedIDsKey = BackupSettingsKeys.uploadedLocalIDs

    private func loadUploadedIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.uploadedIDsKey) ?? [])
    }

    private func saveUploadedIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: Self.uploadedIDsKey)
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        addLog("FAILED: \(message)")
        phase = .failed(message)
    }
}
