import Foundation
import Photos
import SwiftData
import DropboxCore
import MosaicSupport

// MARK: - Engine

/// ローカル写真を Dropbox へバックアップするエンジン。
/// 実行本体（権限→差分算出→アップロードループ→metadata 送信）は `BackupRunner` に、
/// SwiftData 永続化は `BackupStore`（@ModelActor・**オフメイン**）に分離し、
/// ここは @Observable な状態公開（phase / log / アルバム集計 / 各キャッシュ）と
/// 起動・キャンセルの薄いコーディネータに絞る（A1/B1 リファクタリング）。
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
    /// オフロード台帳の総件数（キャッシュ・Developer Options の診断用）。
    @ObservationIgnored private var offloadCount = 0
    /// バックアップ済み localIdentifier のメモリキャッシュ（フル画像ビューのバッジ判定用・同期参照）。
    /// 「UserDefaults 台帳 ∪ SwiftData 記録」。起動時に**オフメインで**ウォームし、
    /// アップロード成功のたびに追記、完了フェーズで読み直す。
    @ObservationIgnored private var backedUpIDs: Set<String> = []
    /// キャッシュのウォーム完了フラグ。完了前のバッジ判定は nil（非表示）を返す
    /// （未ウォームで false を返すと「未バックアップ」と誤表示するため）。
    @ObservationIgnored private var cachesWarmed = false
    /// バックアップ状況（総数・完了数）のキャッシュ（A3）。画面を開くたびの全ライブラリ列挙を避け、
    /// バックアップ完了・記録変更のタイミングで無効化する。
    @ObservationIgnored private var cachedStatus: (total: Int, done: Int)?

    // internal: BackupEngine+Offload（同モジュール extension）からも使う。
    @ObservationIgnored let tokenProvider: AccessTokenProvider
    @ObservationIgnored let uploader: DropboxBackupUploader
    @ObservationIgnored private let progressStore = BackupProgressStore()
    @ObservationIgnored private var backupTask: Task<Void, Never>?
    /// SwiftData ストア（@ModelActor・オフメイン生成）。生成完了を待たずに engine init を返すため
    /// Task で保持し、利用側は `store()` で await する。
    @ObservationIgnored private let storeTask: Task<BackupStore, Never>

    /// SwiftData ストアへのアクセサ（生成完了を待つ）。
    func store() async -> BackupStore { await storeTask.value }

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
    /// ⚠️ SwiftData 記録は残る＝済み判定（台帳∪記録）は変わらない。記録ごと消すのは
    /// `clearAllBackupRecords()`。
    public func clearUploadProgress() {
        progressStore.saveUploadedIDs([])
        invalidateStatus()
        Task { await reloadBackedUpIDs() }
    }

    public init(auth: DropboxAuthService, httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.tokenProvider = auth
        self.uploader = DropboxBackupUploader(httpClient: httpClient)
        // SwiftData は BackupStore（@ModelActor）へ分離し**オフメイン生成**する。
        // 旧実装は init で全記録 fetch×2 がメインで走り、記録が増えると起動ハングの構図だった。
        self.storeTask = Task { await BackupStore.makeDetached() }
        Task { await warmCaches() }
    }

    /// 起動時のキャッシュウォーム（オフロード台帳＋済み ID）。すべてオフメイン（store actor）で
    /// fetch し、完成した値だけをメインで代入する。
    private func warmCaches() async {
        let store = await store()
        async let ledger = store.offloadLedgerSnapshot()
        async let recorded = store.recordedLocalIdentifiers()
        let (byAlbum, count) = await ledger
        offloadedPathsByAlbum = byAlbum
        offloadCount = count
        backedUpIDs = progressStore.loadUploadedIDs().union(await recorded)
        cachesWarmed = true
    }

    // MARK: - Public API

    /// バックアップの実保存先（端末フォルダ・ADR-41）: `<root>/<表示名>-<短ID>`。
    /// 家族で 1 アカウントを共有しても、ファイルも `.mosaic` メタデータも端末ごとに分離される。
    public static func deviceBackupRoot(for rootFolder: String) -> String {
        rootFolder + "/" + BackupDeviceIdentity.currentFolderName()
    }

    public func start(folder: String) {
        guard !isRunning else { return }
        log.removeAll()
        phase = .requestingPermission
        // ADR-41: アップロード・メタデータはすべて端末フォルダ配下に保存する
        //（既存のフラットな旧ファイルは移動しない＝記録はフルパス基準なのでそのまま整合）。
        let deviceRoot = Self.deviceBackupRoot(for: folder)
        addLog("Device folder: \(BackupDeviceIdentity.currentFolderName())")
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
            if await runner.run(folder: deviceRoot) {
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

    // MARK: - Reconcile with Dropbox（照合・実態への修復）

    /// バックアップ記録・台帳を **Dropbox の実ファイル一覧と照合**して実態に合わせる。
    /// - ファイルが存在しない記録 → 削除（次回バックアップで再アップロード対象に戻る）
    /// - content_hash が一致しない記録 → 削除（別物が同パスにある＝信用しない）
    /// - 台帳（UserDefaults）も「照合に合格した記録の localIdentifier」へ**置き換える**
    ///   （409 誤記録時代の「記録なし済み ID」もここで一掃される）
    /// 戻り値: (照合に合格した件数, 削除した記録数, リモートの実ファイル数)。認証/通信失敗は nil。
    public func reconcileWithDropbox() async -> (verified: Int, removed: Int, remoteFiles: Int)? {
        guard let token = try? await tokenProvider.freshAccessToken() else {
            addLog("Reconcile: authentication failed")
            return nil
        }
        let root = backupNormalizedPath(
            UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder)
                ?? BackupSettingsKeys.defaultDropboxFolder)
        guard let remote = await uploader.listFolder(root: root, token: token) else {
            addLog("Reconcile: could not list \(root)")
            return nil
        }
        let (verifiedIDs, removed) = await store().reconcile(remote: remote)
        progressStore.saveUploadedIDs(verifiedIDs)
        invalidateStatus()
        await reloadBackedUpIDs()
        addLog("Reconcile: verified \(verifiedIDs.count), removed \(removed) stale record(s), remote files \(remote.count)")
        await loadAlbums()
        return (verifiedIDs.count, removed, remote.count)
    }

    /// バックアップの記録を**全消去**する（台帳＋SwiftData 記録。オフロード台帳は対象外）。
    /// Debug 用: 次回バックアップは全量が対象に戻る（Dropbox に実在する分は 409→hash 照合で
    /// 再アップロードなしに「済み」へ復帰する）。
    public func clearAllBackupRecords() async {
        progressStore.saveUploadedIDs([])
        await store().deleteAllRecords()
        invalidateStatus()
        await reloadBackedUpIDs()
        addLog("Cleared ALL backup records and upload progress")
        await loadAlbums()
    }

    // MARK: - Nightly auto backup (ADR-42)

    /// 夜間の重い処理ウィンドウ（BGProcessingTask・電源＋Wi-Fi＋非使用）からの自動バックアップ。
    /// 宛先が Dropbox に設定されているときだけ、手動と同じ経路（上限設定・電源/回線ポーズ込み）で
    /// 実行する。実行中なら何もしない。
    public func startNightlyIfEnabled() {
        guard !isRunning else { return }
        let destination = UserDefaults.standard.string(forKey: BackupSettingsKeys.destination)
            .flatMap(BackupDestination.init(rawValue:)) ?? .disabled
        guard destination == .dropbox else { return }
        let folder = backupNormalizedPath(
            UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder)
                ?? BackupSettingsKeys.defaultDropboxFolder)
        addLog("Nightly backup starting…")
        start(folder: folder)
    }

    // MARK: - Backup status (画面表示用・A3 キャッシュつき)

    /// バックアップ状況（対象総数・完了数）。結果はキャッシュし、バックアップ完了・記録変更で
    /// 無効化する（画面を開くたびの全ライブラリ列挙を避ける）。ライブラリ全列挙はオフメイン。
    /// 完了数は「現在ライブラリにある写真のうちバックアップ済み記録があるもの」
    /// （削除済み写真の記録は数えない＝残数が負にならない）。
    public func backupStatus() async -> (total: Int, done: Int) {
        if let cachedStatus { return cachedStatus }
        if !cachesWarmed { await warmCaches() }
        let doneIDs = backedUpIDs
        let status = await Task.detached(priority: .userInitiated) {
            let result = PHAsset.fetchAssets(with: .image, options: nil)
            var total = 0
            var done = 0
            result.enumerateObjects { asset, _, _ in
                total += 1
                if doneIDs.contains(asset.localIdentifier) { done += 1 }
            }
            return (total, done)
        }.value
        cachedStatus = status
        return status
    }

    /// 状況キャッシュの無効化（記録・台帳が変わったとき）。
    private func invalidateStatus() {
        cachedStatus = nil
    }

    // MARK: - Backed-up lookup

    /// この localIdentifier の写真は Dropbox へバックアップ済みか（フル画像ビューのバッジ用）。
    /// キャッシュのウォーム前は nil（呼び出し側はバッジ非表示にする＝誤って「未バックアップ」を
    /// 出さない）。
    public func isBackedUp(localIdentifier: String) -> Bool? {
        guard cachesWarmed else { return nil }
        return backedUpIDs.contains(localIdentifier)
    }

    /// バックアップ済み ID キャッシュを「UserDefaults 台帳 ∪ SwiftData 記録」から読み直す。
    /// 記録は実アップロード成功時にのみ追加される確かな出典（台帳クリア後も残る）。
    func reloadBackedUpIDs() async {
        let recorded = await store().recordedLocalIdentifiers()
        backedUpIDs = progressStore.loadUploadedIDs().union(recorded)
        cachesWarmed = true
    }

    // MARK: - Offload ledger (ADR-39)

    /// アルバム名に対するクラウド代替（オフロード済み写真の Dropbox パス・撮影日昇順）。
    /// 端末アルバムの合成表示（DeviceAlbumPhotosView）が cloudPathFilter に使う。同期・キャッシュ参照。
    public func offloadedPaths(inAlbum name: String) -> [String] {
        offloadedPathsByAlbum[name] ?? []
    }

    /// 台帳の総件数（Developer Options の診断用・キャッシュ参照）。
    public var offloadRecordCount: Int { offloadCount }

    /// オフロード実行の記録（オフロード機能が**削除の直前**に呼ぶ）。upsert・完了まで await。
    public func recordOffloads(_ items: [(localIdentifier: String, dropboxPath: String,
                                          albums: [String], captureDate: Date?, contentHash: String?)]) async {
        await store().upsertOffloads(items)
        await reloadOffloadLedger()
        invalidateStatus()
    }

    /// 台帳からの削除（復元＝端末へ再取り込みしたとき・削除キャンセルのロールバック）。
    public func removeOffloads(localIdentifiers: [String]) async {
        await store().removeOffloads(localIdentifiers: localIdentifiers)
        await reloadOffloadLedger()
    }

    /// 機種変更・再インストール後の台帳再構築: metadata v2 の `offloadedAt` マーカー付き
    /// エントリから復元する（ユーザー削除の写真は対象外＝マーカーの有無で区別）。
    /// 既存台帳が空のときだけ実行する（実端末の台帳が正）。
    public func rebuildOffloadLedgerIfEmpty(from metadata: DropboxBackupMetadata) async {
        if !cachesWarmed { await warmCaches() }
        guard offloadRecordCount == 0 else { return }
        let candidates = BackupMetadataPlanning.offloadCandidates(from: metadata.entries)
        guard !candidates.isEmpty else { return }
        addLog("Rebuilding offload ledger from metadata (\(candidates.count) entries)…")
        await recordOffloads(candidates)
    }

    /// 台帳キャッシュを store から読み直す（変更時）。
    func reloadOffloadLedger() async {
        let (byAlbum, count) = await store().offloadLedgerSnapshot()
        offloadedPathsByAlbum = byAlbum
        offloadCount = count
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
        // 完了時に台帳∪記録から読み直す（409＝Dropbox に既存で「済み」扱いになった分は
        // runnerSaveRecord を通らないため、ここで確実に取り込む）。状況キャッシュも無効化。
        if case .completed = newPhase {
            invalidateStatus()
            Task { await reloadBackedUpIDs() }
        }
    }

    func runnerLog(_ message: String) {
        addLog(message)
    }

    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?) {
        // 永続化はオフメイン（store actor）。バッジ判定キャッシュだけ即時更新する。
        let localIdentifier = asset.localIdentifier
        let creationDate = asset.creationDate
        Task {
            await store().upsertRecord(dropboxPath: dropboxPath, localIdentifier: localIdentifier,
                                       filename: filename, creationDate: creationDate,
                                       contentHash: contentHash,
                                       people: people, albums: albums, isFavorite: isFavorite)
        }
        backedUpIDs.insert(localIdentifier)
        invalidateStatus()
    }

    func runnerRecordedLocalIdentifiers() async -> Set<String> {
        await store().recordedLocalIdentifiers()
    }
}
