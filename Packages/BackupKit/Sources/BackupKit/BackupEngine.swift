import Foundation
import Photos
import SwiftData
import DropboxCore
import MosaicSupport

// MARK: - Engine

/// ローカル写真を Dropbox へバックアップするエンジン。
/// 実行本体（権限→差分算出→アップロードループ→metadata 送信）は `BackupRunner` に分離し、
/// ここは @Observable な状態公開（phase / log / アルバム集計）と起動・キャンセルの
/// 薄いコーディネータに絞る。進捗の UI 反映は `BackupRunnerDelegate` 適合（ファイル末尾）で受ける。
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
    /// オフロード台帳のメモリキャッシュ: アルバム名 → クラウド代替の Dropbox パス（撮影日昇順）。
    /// 端末アルバムを開くたびに SwiftData を引かず同期参照できるようにする（台帳が空なら空辞書）。
    @ObservationIgnored private var offloadedPathsByAlbum: [String: [String]] = [:]

    // SwiftData レコード/アルバム永続化は BackupEngine+Store.swift（extension）に分離しているため、
    // そこから参照する modelContext / addLog / 上記の集計状態は internal にしている。
    @ObservationIgnored private let tokenProvider: AccessTokenProvider
    @ObservationIgnored private let uploader: DropboxBackupUploader
    @ObservationIgnored private let progressStore = BackupProgressStore()
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

    /// 人物名（localIdentifier → 命名済み顔クラスタのフルネーム）を返す seam（ADR-38）。
    /// BackupKit は AutoAlbumCore に依存しないため、アプリ（Composition Root）が PeopleEngine を結線する。
    @ObservationIgnored public var peopleNamesProvider: (@Sendable () async -> [String: [String]])?
    /// VLM キャプション（localIdentifier → 説明文）を返す seam（ADR-38）。アプリが TagStore を結線する。
    @ObservationIgnored public var captionsProvider: (@Sendable ([String]) async -> [String: String])?

    /// 実効アップロード上限。設定キーが存在すればその値、無ければ `debugUploadLimit`。
    var effectiveUploadLimit: Int {
        UserDefaults.standard.object(forKey: BackupSettingsKeys.uploadLimit) == nil
            ? debugUploadLimit
            : UserDefaults.standard.integer(forKey: BackupSettingsKeys.uploadLimit)
    }

    /// バックアップ進捗として保存済みのローカル ID 数（設定表示用）。
    public var uploadedIDCount: Int { progressStore.loadUploadedIDs().count }

    /// metadata.json のパス接尾辞（設定の Debug 表示用）。
    public static var metadataPathSuffix: String { metadataSuffix }

    /// バックアップ進捗（アップロード済み ID 一覧）を消去する。次回は全件再判定になる（Debug 用）。
    public func clearUploadProgress() {
        progressStore.saveUploadedIDs([])
    }

    public init(auth: DropboxAuthService, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = auth
        self.uploader = DropboxBackupUploader(httpClient: httpClient)
        // ⚠️ 名前を明示して "BackupKit.store" を使う（名前なしは "default.store" になり
        // DropboxCacheStore と衝突＝過去にクラッシュ）。壊れた/非互換ストアは削除して作り直す（自己修復）。
        modelContext = ModelContext(Self.makeResilientContainer())
        reloadOffloadLedger()
    }

    /// 名前付き永続コンテナを作る。失敗時は store ファイルを削除して再構築し、それでも駄目なら
    /// インメモリへ。SwiftData が trap せず必ず ModelContainer を返し、起動時クラッシュを防ぐ
    /// （バックアップ記録は再構築されるが、Dropbox 上の実ファイルは無事）。
    /// 実体は MosaicSupport の共通ロジック（自己修復）。
    private static func makeResilientContainer() -> ModelContainer {
        let schema = Schema([BackupAssetRecord.self, OffloadRecord.self])
        return makeResilientModelContainer(
            name: "BackupKit", schema: schema,
            openFailedMessage: "BackupEngine: 'BackupKit' store open failed; deleting and rebuilding.",
            memoryFallbackMessage: "BackupEngine: 'BackupKit' store still failing; using in-memory store.",
            log: { BackupLogger.error($0) })
    }

    // MARK: - Public API

    public func start(folder: String) {
        guard !isRunning else { return }
        log.removeAll()
        phase = .requestingPermission
        backupTask = Task { [weak self] in
            guard let self else { return }
            let runner = BackupRunner(
                tokenProvider: self.tokenProvider,
                uploader: self.uploader,
                progressStore: self.progressStore,
                uploadLimit: { self.effectiveUploadLimit },
                delegate: self,
                peopleNamesProvider: self.peopleNamesProvider,
                captionsProvider: self.captionsProvider
            )
            // 完走時のみアルバム一覧を更新する（runner の戻り値で通知される）。
            if await runner.run(folder: folder) {
                await self.loadAlbums()
            }
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

    // MARK: - Offload ledger (ADR-39)

    /// アルバム名に対するクラウド代替（オフロード済み写真の Dropbox パス・撮影日昇順）。
    /// 端末アルバムの合成表示（DeviceAlbumPhotosView）が cloudPathFilter に使う。同期・キャッシュ参照。
    public func offloadedPaths(inAlbum name: String) -> [String] {
        offloadedPathsByAlbum[name] ?? []
    }

    /// 台帳の総件数（Developer Options の診断用）。
    public var offloadRecordCount: Int {
        offloadedPathsByAlbum.values.reduce(0) { $0 + $1.count }
    }

    /// オフロード実行の記録（将来のオフロード機能が削除の直後に呼ぶ）。upsert。
    public func recordOffloads(_ items: [(localIdentifier: String, dropboxPath: String,
                                          albums: [String], captureDate: Date?, contentHash: String?)]) {
        guard let context = modelContext else { return }
        for item in items {
            let id = item.localIdentifier
            let descriptor = FetchDescriptor<OffloadRecord>(
                predicate: #Predicate { $0.localIdentifier == id })
            if let existing = try? context.fetch(descriptor).first {
                context.delete(existing)
            }
            context.insert(OffloadRecord(localIdentifier: item.localIdentifier,
                                         dropboxPath: item.dropboxPath.lowercased(),
                                         albums: item.albums,
                                         captureDate: item.captureDate,
                                         contentHash: item.contentHash))
        }
        try? context.save()
        reloadOffloadLedger()
    }

    /// 台帳からの削除（復元＝端末へ再取り込みしたとき）。
    public func removeOffloads(localIdentifiers: [String]) {
        guard let context = modelContext else { return }
        let ids = Set(localIdentifiers)
        let all = (try? context.fetch(FetchDescriptor<OffloadRecord>())) ?? []
        for record in all where ids.contains(record.localIdentifier) {
            context.delete(record)
        }
        try? context.save()
        reloadOffloadLedger()
    }

    /// 機種変更・再インストール後の台帳再構築: metadata v2 の `offloadedAt` マーカー付き
    /// エントリから復元する（ユーザー削除の写真は対象外＝マーカーの有無で区別）。
    /// 既存台帳が空のときだけ実行する（実端末の台帳が正）。
    public func rebuildOffloadLedgerIfEmpty(from metadata: DropboxBackupMetadata) {
        guard offloadRecordCount == 0 else { return }
        let candidates = BackupMetadataPlanning.offloadCandidates(from: metadata.entries)
        guard !candidates.isEmpty else { return }
        addLog("Rebuilding offload ledger from metadata (\(candidates.count) entries)…")
        recordOffloads(candidates)
    }

    /// 台帳を SwiftData から読み直してメモリキャッシュを更新する（起動時・変更時）。
    func reloadOffloadLedger() {
        guard let context = modelContext,
              let records = try? context.fetch(FetchDescriptor<OffloadRecord>()) else {
            offloadedPathsByAlbum = [:]
            return
        }
        var byAlbum: [String: [(Date?, String)]] = [:]
        for record in records {
            for album in record.albums {
                byAlbum[album, default: []].append((record.captureDate, record.dropboxPath))
            }
        }
        offloadedPathsByAlbum = byAlbum.mapValues { list in
            list.sorted { ($0.0 ?? .distantPast) < ($1.0 ?? .distantPast) }.map(\.1)
        }
    }

    // MARK: - Logging

    func addLog(_ message: String) {
        log.append(BackupLogEntry(message))
    }

    // MARK: - Metadata

    static let metadataSuffix = "/.mosaic/metadata.json"
}

// MARK: - BackupRunnerDelegate

/// `BackupRunner` からの進捗・ログ・レコード保存を @Observable な状態に反映する。
/// phase は `private(set)` のため、同一ファイル内の extension で受ける。
extension BackupEngine: BackupRunnerDelegate {

    func runnerSetPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    func runnerLog(_ message: String) {
        addLog(message)
    }

    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool) {
        saveRecord(dropboxPath: dropboxPath, asset: asset, filename: filename,
                   people: people, albums: albums, isFavorite: isFavorite)
    }

}
