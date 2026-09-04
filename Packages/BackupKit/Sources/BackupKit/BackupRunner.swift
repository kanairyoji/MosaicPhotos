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
    /// - Returns: **永続化できたか**。false なら進捗台帳へ入れない
    ///   （入れると次回は再アップロードされないのに記録が無い＝オフロード・アルバム・共有が
    ///   参照できない写真になる・レビュー指摘）。
    func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                          people: [String], albums: [String], isFavorite: Bool,
                          contentHash: String?) async -> Bool
    /// SwiftData 記録にある「実際にアップロード済み」の localIdentifier 集合。
    /// UserDefaults の台帳が消えても（Clear upload progress・再インストール等）、
    /// 記録から差分判定を自己修復し**二重アップロードを防ぐ**（実障害: 台帳クリア＋
    /// 端末フォルダ移行の組み合わせで同一写真がルートと端末フォルダに重複した）。
    func runnerRecordedLocalIdentifiers() async -> Set<String>
    /// バックアップを優先すべき localIdentifier（クラウド共有で待たれている写真・ADR-112）。
    func runnerPriorityLocalIdentifiers() async -> Set<String>
    /// 現在の Dropbox アカウントの指紋（保留メタデータのキューをアカウントごとに分けるため）。
    /// 生の accountId は扱わない（等値比較にしか使わないので指紋で足りる）。
    func runnerAccountFingerprint() async -> String?
}

/// 世代が一致するときだけ本体へ通す委譲プロキシ。
///
/// ⚠️ `cancel()` は旧タスクの終了を待たずに次の実行を始められる。旧タスクは自分が
/// 現行だと思ったまま `phase` を更新し続けるので、**新しい実行の進捗を古い実行が
/// 上書きする**（レビュー指摘）。実行ごとに世代を採番し、ここで食い止める。
final class GenerationScopedRunnerDelegate: BackupRunnerDelegate {
    private weak var base: BackupEngine?
    private let generation: Int

    init(base: BackupEngine, generation: Int) {
        self.base = base
        self.generation = generation
    }

    @MainActor private var isCurrent: Bool { base?.isCurrentRun(generation) ?? false }

    @MainActor func runnerSetPhase(_ phase: BackupEngine.Phase) {
        guard isCurrent else { return }
        base?.runnerSetPhase(phase)
    }

    @MainActor func runnerLog(_ message: String) {
        guard isCurrent else { return }
        base?.runnerLog(message)
    }

    @MainActor func runnerSaveRecord(dropboxPath: String, asset: PHAsset, filename: String,
                                     people: [String], albums: [String], isFavorite: Bool,
                                     contentHash: String?) async -> Bool {
        // ⚠️ 記録は世代に関わらず残す。アップロード自体は完了しているので、
        // ここで捨てると**実体はあるのに記録が無い**（次回また上げてしまう）。
        await base?.runnerSaveRecord(dropboxPath: dropboxPath, asset: asset, filename: filename,
                                     people: people, albums: albums, isFavorite: isFavorite,
                                     contentHash: contentHash) ?? false
    }

    func runnerRecordedLocalIdentifiers() async -> Set<String> {
        await base?.runnerRecordedLocalIdentifiers() ?? []
    }

    func runnerPriorityLocalIdentifiers() async -> Set<String> {
        await base?.runnerPriorityLocalIdentifiers() ?? []
    }

    func runnerAccountFingerprint() async -> String? {
        await base?.runnerAccountFingerprint()
    }
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
    /// 背景アップロード（ADR-181）。nil なら従来の前面経路だけ。
    let backgroundUploads: BackgroundUploadEnqueuing?
    let spool: UploadSpool
    let spoolPolicy: BackgroundUploadPolicy
    /// この実行で背景アップロードを使うか（夜間＝窓の外へ転送を持ち出したい回だけ）。
    private let useBackgroundUploads: () -> Bool
    init(
        tokenProvider: AccessTokenProvider,
        uploader: DropboxBackupUploader,
        progressStore: BackupProgressStore,
        uploadLimit: @escaping () -> Int,
        delegate: BackupRunnerDelegate,
        peopleNamesProvider: (@Sendable () async -> [String: [String]])? = nil,
        backgroundUploads: BackgroundUploadEnqueuing? = nil,
        spool: UploadSpool = UploadSpool(),
        spoolPolicy: BackgroundUploadPolicy = BackgroundUploadPolicy(),
        useBackgroundUploads: @escaping () -> Bool = { false }
    ) {
        self.tokenProvider = tokenProvider
        self.uploader = uploader
        self.progressStore = progressStore
        self.uploadLimit = uploadLimit
        self.delegate = delegate
        self.peopleNamesProvider = peopleNamesProvider
        self.backgroundUploads = backgroundUploads
        self.spool = spool
        self.spoolPolicy = spoolPolicy
        self.useBackgroundUploads = useBackgroundUploads
    }

    /// 背景アップロードを行ってよいか（電源＋回線ポリシー）。アップロードループの一時停止判定に使う。
    private var backgroundUploadAllowed: Bool {
        PowerStateMonitor.shared.backgroundAllowed() && NetworkStateMonitor.shared.networkAllowed()
    }

    // MARK: - フェーズ間で受け渡す値

    /// フェーズ 2 の成果物（端末側の索引）。
    /// （internal＝`writeMetadata` を直接叩くテストから組み立てられるようにするため）
    struct Indexes {
        let people: [String: [String]]      // localIdentifier → 人物名（顔クラスタ・ユーザー命名）
        let albums: [String: [String]]      // localIdentifier → 所属アルバム名
        let albumIDs: [String: String]      // アルバム名 → PHAssetCollection.localIdentifier
    }

    /// アップロードループの集計。
    struct UploadTally {
        var uploaded = 0
        /// OS に渡した数（背景アップロード・ADR-181。「済み」ではない＝応答で確定する）。
        var spooled = 0
        var skippedRead = 0
        /// spool の集計（初回に走査して以後は加算・ADR-181）。nil＝未走査。
        var spoolJobCount: Int?
        var spoolBytes = 0
        var trackedIDs: Set<String>
        var newEntries: [BackupMetadataPlanning.NewEntry] = []
    }

    /// 1 枚のアップロード結果。
    enum ItemOutcome {
        case done            // 成功（tally 更新済み）
        case skipped         // 読み込みスキップ（続行）
        case fatal           // 実行を止める（fail 済み・進捗保存済み）
        case spoolFull       // 背景 spool が上限（この窓はここまで・残りは次の窓）
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

        // 再送キューの名前空間はアカウント＋保存先で決まる。1 枚ごとに await しないよう控える。
        cachedAccountFingerprint = await delegate.runnerAccountFingerprint()
        cachedPendingStore = nil

        // 3-4. 全アセット取得 → 差分算出（済み＝台帳∪記録・上限適用）
        let assets = fetchAssetsSorted()
        guard !Task.isCancelled else { setPhase(.cancelled); return false }
        var (pending, alreadySkipped, doneIDs) = await computePending(assets: assets)
        // ADR-181: 背景セッションが転送中の写真は対象から外し、409 を受けた写真は前面経路へ回す。
        let background = backgroundUploads != nil && useBackgroundUploads()
        let bgPlan = background ? backgroundPlan() : BackgroundPlan()
        if !bgPlan.inFlight.isEmpty {
            pending.removeAll { bgPlan.inFlight.contains($0.localIdentifier) }
            addLog("In flight (background session): \(bgPlan.inFlight.count)")
        }
        guard !pending.isEmpty else {
            // ⚠️ 写真が全部バックアップ済みでも、**前回送れなかったメタデータ**が残っていれば
            // ここで送り直す。早期 return してしまうと、新しい写真が増えるまでキューが
            // 永久に滞留する（人物名・位置・アルバムが欠けたまま・レビュー指摘）。
            await drainPendingMetadataIfNeeded(folder: folder)
            // ADR-181: 対象が無くても、前の窓で積んだまま渡せなかった spool は OS へ渡す。
            if background, !bgPlan.inFlight.isEmpty, let token = try? await tokenProvider.freshAccessToken() {
                await flushSpool(token: token)
            }
            addLog("Nothing to upload.")
            setPhase(.completed(uploaded: 0, skipped: alreadySkipped))
            return false
        }

        // 5. Dropbox 認証
        addLog("Fetching Dropbox access token…")
        guard let token = try? await tokenProvider.freshAccessToken() else {
            fail("Authentication failed")
            return false
        }
        addLog("Token OK")
        // ADR-181: 前の窓で積んだまま渡せなかった分を先に OS へ（無条件・上の注記）。
        if background { await flushSpool(token: token) }

        // 6. 1 枚ずつアップロード（検証つき・電源/回線ポーズ・キャンセル対応）
        //
        // ⚠️ **次の 1 枚の読み込みを、現在の 1 枚のアップロード中に走らせる**（ADR-84）。
        // 読み込み（PHAssetResource のディスク読み）とアップロード（HTTP）は別資源なので、
        // 直列にすると読み込み時間がまるごと待ち時間になる。先読みは**ちょうど 1 枚**に限定し、
        // メモリ増を写真 1 枚分に抑える（夜間 BGTask は jetsam 上限が厳しい＝ADR-72）。
        // 検証・記録（ADR-40 の hash 照合と「済み」記録）の順序は一切変えない。
        var tally = UploadTally(trackedIDs: doneIDs)
        var readAhead: Task<FetchDataResult, Never>?
        /// 中断・打ち切りの共通の出口: 積んだ分だけは OS へ渡してから帰る。
        func bail(_ phase: BackupEngine.Phase?) async -> Bool {
            readAhead = nil
            await flushSpool(token: token)
            if let phase { setPhase(phase) }
            return false
        }
        uploadLoop: for (i, asset) in pending.enumerated() {
            guard !Task.isCancelled else { return await bail(.cancelled) }
            guard await waitUntilUploadAllowed() else { return await bail(.cancelled) }

            // 現在の 1 枚: 先読み済みならそれを使い、無ければ（初回・中断後）ここで読む。
            let fetched: FetchDataResult
            if let readAhead {
                fetched = await readAhead.value
            } else {
                fetched = await Self.readAsset(asset)
            }
            readAhead = nil

            // 次の 1 枚の読み込みを開始（このあとのアップロードと重なる）。
            // ゲートが閉じている間に読み込んで抱え続けないよう、開いているときだけ先読みする。
            if i + 1 < pending.count, !Task.isCancelled, backgroundUploadAllowed {
                let next = pending[i + 1]
                readAhead = Task { await Self.readAsset(next) }
            }

            // ADR-181: 夜間は spool に積んで OS に渡す（応答は窓の外で受ける）。
            // 409 を受けた写真だけは前面経路（hash 照合・autorename）で片付ける。
            let outcome: ItemOutcome
            if background, !bgPlan.conflicts.contains(asset.localIdentifier) {
                outcome = spoolOne(asset: asset, fetched: fetched, index: i, total: pending.count,
                                   folder: folder, indexes: indexes, tally: &tally)
            } else {
                outcome = await uploadOne(asset: asset, fetched: fetched, index: i, total: pending.count,
                                          folder: folder, token: token,
                                          indexes: indexes, tally: &tally)
            }
            switch outcome {
            case .done, .skipped:
                // 積んだ分は小刻みに OS へ渡す（窓の期限で止まっても、渡した分は転送が続く）。
                if tally.spooled > 0, tally.spooled % Self.spoolFlushEvery == 0 {
                    await flushSpool(token: token)
                }
            case .fatal:
                return await bail(nil)   // fail 済み（phase は設定済み）
            case .spoolFull:
                addLog("Background spool is full — the rest waits for the next window")
                readAhead = nil
                break uploadLoop
            }
        }
        readAhead = nil
        progressStore.saveUploadedIDs(tally.trackedIDs)
        await flushSpool(token: token)

        // 7. メタデータ v2（触った撮影月シャード＋カタログ）
        await writeMetadata(newEntries: tally.newEntries, indexes: indexes,
                            folder: folder, token: token)

        let totalSkipped = alreadySkipped + tally.skippedRead
            + (pending.count - tally.uploaded - tally.spooled - tally.skippedRead)
        let handedOff = tally.spooled > 0 ? ", handed to OS: \(tally.spooled)" : ""
        if metadataLost > 0 {
            // メタデータを失った回は「完了」と言い切らない（写真本体は上がっている）。
            addLog("Done with warnings — uploaded: \(tally.uploaded)\(handedOff), skipped: \(totalSkipped), "
                   + "metadata lost: \(metadataLost)")
        } else {
            addLog("Done — uploaded: \(tally.uploaded)\(handedOff), skipped: \(totalSkipped)")
        }
        // 完了は診断ログにも残す（ADR-86・addLog はアプリ内バッファのみ＝実行有無が追えなかった）。
        Diagnostics.mark("backup: done — uploaded=\(tally.uploaded) spooled=\(tally.spooled) skipped=\(totalSkipped)")
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
        var pending = assets.filter { pendingSet.contains($0.localIdentifier) }
        // クラウド共有で待たれている写真を先頭へ（安定・相対順は維持）。共有セットの
        // 「バックアップ待ち」が夜間バックアップの進行を何日も待たされるのを防ぐ（ADR-112）。
        let priority = await delegate.runnerPriorityLocalIdentifiers()
        if !priority.isEmpty {
            let first = pending.filter { priority.contains($0.localIdentifier) }
            if !first.isEmpty {
                pending = first + pending.filter { !priority.contains($0.localIdentifier) }
                addLog("Prioritizing \(first.count) photo(s) awaited by Cloud Sharing")
            }
        }
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

    /// 写真本体を読む（先読みと本流の共通経路・ADR-84）。所要は `backup.read` に計測する。
    /// フォールバック名は localIdentifier 由来の安定名（旧: 実行内インデックス名は
    /// 実行ごとに 1 から振り直され、別の写真が同名になって 409 を誘発する設計バグだった）。
    private static func readAsset(_ asset: PHAsset) async -> FetchDataResult {
        let stableFallback = "photo_" + asset.localIdentifier.prefix(8)
            .replacingOccurrences(of: "/", with: "-") + ".jpg"
        let t0 = PerfTrace.nowNs()
        let result = await BackupAssetReader.read(asset: asset, fallback: stableFallback)
        PerfTrace.count("backup.readMs", value: PerfTrace.msSince(t0))
        return result
    }

    /// 1 枚のアップロード（検証つきアップロード → 409 の hash 照合 → 記録）。
    /// 読み込みは呼び出し側が先読みして渡す（ADR-84）＝アップロードと重ねるため。
    private func uploadOne(asset: PHAsset, fetched fetchResult: FetchDataResult,
                           index i: Int, total: Int,
                           folder: String, token: String,
                           indexes: Indexes,
                           tally: inout UploadTally) async -> ItemOutcome {
        guard case .success(let data, let filename, _) = fetchResult else {
            if case .skipped(let filename, let reason) = fetchResult {
                addLog("[\(i+1)/\(total)] SKIP \(filename): \(reason)")
                tally.skippedRead += 1
            }
            return .skipped
        }

        setPhase(.uploading(current: i + 1, total: total, filename: filename))
        guard !Task.isCancelled else { setPhase(.cancelled); return .fatal }

        // ADR-176: 写真は撮影年月のフォルダへ（`files/upload` は中間フォルダを自動で作る）。
        let dropboxPath = BackupLayout.photoFolder(backupRoot: folder,
                                                   captureDate: asset.creationDate) + "/" + filename
        addLog("[\(i+1)/\(total)] \(filename) (\(data.count) bytes) → \(dropboxPath)")

        // ADR-40: ローカルで content_hash を計算し、応答の hash と一致して初めて「済み」にする。
        let localHash = DropboxContentHash.hash(of: data)
        let tUpload = PerfTrace.nowNs()
        // 撮影日を送る（省略すると副本が「アップロードした日の写真」になる・下記 uploader の注記）。
        var result = await uploader.upload(data: data, to: dropboxPath, token: token,
                                           expectedHash: localHash,
                                           clientModified: asset.creationDate)
        // 計測: 読み込み（backup.readMs）と対にして、どちらが支配的かを実測で判断できるようにする。
        PerfTrace.count("backup.uploadMs", value: PerfTrace.msSince(tUpload))
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
                                               expectedHash: localHash, autorename: true,
                                               clientModified: asset.creationDate)
            }
        }

        switch result {
        case .uploaded(let savedPath, let hash):
            tally.uploaded += 1
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
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
                )))
            // ⚠️ **メタデータを先に永続化してから**完了記録を保存する（ADR-171）。
            // 逆順だと、その間に中断されたとき「写真は済み・メタデータは無い」が確定する
            // ——写真本体は進捗台帳に載って次回の対象から外れるので、人物名・アルバム・
            // 位置情報は**二度と作られない**。実行の最後にまとめて送る旧実装は、
            // 途中終了で **それまでの全件**を失っていた（レビュー指摘）。
            let queuedMeta = pendingStore(folder: folder).appendEntry(
                shard: BackupMetadataV2.shardName(for: asset.creationDate),
                path: savedPath, entry: tally.newEntries[tally.newEntries.count - 1].entry)
            if !queuedMeta {
                // 永続化できないなら完了記録も作らない＝次回この写真をもう一度通す
                //（実体は Dropbox にあるので 409/hash 照合で再アップロードは起きない）。
                addLog("  ⚠️ metadata could not be queued — leaving photo for next run")
                Diagnostics.mark("backup: metadata journal write failed — \(filename)")
                return .done
            }
            // ⚠️ 記録の**永続化を待ってから**進捗台帳へ入れる。fire-and-forget だと、
            // 大量アップロード後や BGTask 終了時に保存タスクが残ったままアプリが止まり、
            // 「次回は再アップロードされないのに SwiftData 記録が無い」写真ができる
            // （オフロード・アルバム・共有がその写真を辿れなくなる・レビュー指摘）。
            let recorded = await delegate.runnerSaveRecord(
                dropboxPath: savedPath, asset: asset, filename: filename,
                people: people, albums: albums, isFavorite: isFavorite,
                contentHash: hash
            )
            if recorded {
                tally.trackedIDs.insert(asset.localIdentifier)
            } else {
                // 記録できていない＝次回また上げ直す（実体は Dropbox にあるので
                // 409/hash 照合でスキップされ、記録だけが作られる）。
                addLog("  ⚠️ record not saved — will re-check next run")
            }
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
    /// 送信も再送キューへの保存も失敗した件数（0 なら健全）。完了メッセージに反映する。
    private var metadataLost = 0
    /// 再送キューの控え（1 枚ごとに作り直さない）と、その材料のアカウント指紋。
    private var cachedPendingStore: PendingMetadataStore?
    private var cachedAccountFingerprint: String?

    /// （internal＝カタログ経路の回帰テストから直接呼ぶため。本番の呼び出しは `run` のみ）
    func writeMetadata(newEntries: [BackupMetadataPlanning.NewEntry],
                       indexes: Indexes, folder: String, token: String) async {
        // ⚠️ 前回送れなかった分を**先に取り込む**。写真の実体は既にアップロード済みで、
        // その ID は二度と pending に入らないため、ここで送り直さないとメタデータの
        // 欠落が永久化する（レビュー指摘）。
        let pendingStore = PendingMetadataStore(
            account: await delegate.runnerAccountFingerprint(), folder: folder)
        let carried = pendingStore.load()
        let byShard = PendingMetadataStore.merged(
            pending: carried, adding: BackupMetadataPlanning.groupedByShard(newEntries))
        guard !byShard.isEmpty else { return }
        setPhase(.uploadingMetadata)
        if !carried.isEmpty {
            addLog("Re-sending \(PendingMetadataStore.entryCount(carried)) metadata entry(s) from a previous run…")
        }
        addLog("Uploading metadata v2 (\(PendingMetadataStore.entryCount(byShard)) entries → \(byShard.count) shard(s))…")
        let writer = MetadataShardWriter(uploader: uploader, token: token)
        let applied = await writer.applyEntries(byShard: byShard, folder: folder) { line in
            self.addLog(line)
        }

        let catalogPath = folder + BackupMetadataV2.catalogSuffix
        // カタログも取得失敗と不在を区別する（失敗時は既存を壊さないよう書かない）。
        var catalogWritten = false
        switch await uploader.downloadResult(path: catalogPath, token: token) {
        case .found(let data):
            catalogWritten = await uploadCatalog(existing: data, touched: applied.written,
                                                 indexes: indexes, path: catalogPath, token: token)
        case .notFound:
            catalogWritten = await uploadCatalog(existing: nil, touched: applied.written,
                                                 indexes: indexes, path: catalogPath, token: token)
        case .failure(let reason):
            addLog("  catalog.json: skipped — could not read existing (\(reason))")
        }

        // 失敗分を保存（成功したら記録を消す）。カタログだけ失敗した場合も、次回の実行で
        // シャードを書き直す＝カタログも作り直されるように、書けたシャードを残しておく。
        var stillPending = applied.failed
        if !catalogWritten, !applied.written.isEmpty {
            for shard in applied.written where stillPending[shard] == nil {
                stillPending[shard] = byShard[shard] ?? [:]
            }
        }
        // ⚠️ **本体へ書いてからジャーナルを消す**（順序が逆だと、消してから保存に失敗した瞬間に
        // 残りが失われる）。`save` は残す分を本体へ書き切るので、成功後のジャーナルは不要。
        let queued = pendingStore.save(stillPending)
        if queued { pendingStore.clearJournal() }
        if !stillPending.isEmpty {
            let count = PendingMetadataStore.entryCount(stillPending)
            if queued {
                addLog("  ⚠️ \(count) metadata entry(s) could not be written — will retry next run")
                Diagnostics.mark("backup: metadata pending=\(count) shards=\(stillPending.count)")
            } else {
                // ⚠️ 送信も再送キューへの保存も失敗＝**この分は失われる**。写真本体は進捗台帳に
                // 載って次回の対象から外れるので、黙って完了にしない（レビュー指摘）。
                metadataLost = count
                addLog("  ✗ \(count) metadata entry(s) lost — could not send or queue for retry")
                Diagnostics.mark("backup: metadata LOST=\(count) (send and queue both failed)")
            }
        }
        // メタデータを書いた＝「不在」の記録は無効。これを消さないと、初回バックアップ後も
        // 最大 TTL のあいだ起動時の読み込みが不在記録で素通りしてしまう（ADR-82）。
        BackupMetadataAbsence.invalidateAll()
    }

    /// アップロード対象が無い回に、保留メタデータだけを送り直す。
    /// カタログは触らない（このパスでは albums/people の索引を作っていないため、
    /// 空の索引で上書きすると**既存のカタログから名前が消える**）。
    /// 再送キュー（アカウント＋保存先ごと）。1 枚ごとに作り直さないよう控える。
    func pendingStore(folder: String) -> PendingMetadataStore {
        if let cached = cachedPendingStore { return cached }
        let store = PendingMetadataStore(account: cachedAccountFingerprint, folder: folder)
        cachedPendingStore = store
        return store
    }

    private func drainPendingMetadataIfNeeded(folder: String) async {
        let account = await delegate.runnerAccountFingerprint()
        await drainPendingMetadata(folder: folder,
                                   pendingStore: PendingMetadataStore(account: account, folder: folder))
    }

    /// 保留キューを指定して送り直す（キューの置き場所を差し替えられるようにした本体）。
    func drainPendingMetadata(folder: String, pendingStore: PendingMetadataStore) async {
        let carried = pendingStore.load()
        guard !carried.isEmpty else { return }

        guard let token = try? await tokenProvider.freshAccessToken() else {
            addLog("Pending metadata: not connected — will retry next run")
            return
        }
        setPhase(.uploadingMetadata)
        addLog("Re-sending \(PendingMetadataStore.entryCount(carried)) metadata entry(s) from a previous run…")
        let writer = MetadataShardWriter(uploader: uploader, token: token)
        let applied = await writer.applyEntries(byShard: carried, folder: folder) { line in
            self.addLog(line)
        }
        if !pendingStore.save(applied.failed) {
            metadataLost = PendingMetadataStore.entryCount(applied.failed)
            addLog("  ✗ \(metadataLost) metadata entry(s) lost — could not send or queue for retry")
        }
        if !applied.written.isEmpty { BackupMetadataAbsence.invalidateAll() }
    }

    /// カタログを書く。書けたか返す。
    private func uploadCatalog(existing: Data?, touched: [String], indexes: Indexes,
                               path: String, token: String) async -> Bool {
        let albumNames = Array(Set(indexes.albums.values.flatMap { $0 })).sorted()
        let peopleNames = Array(Set(indexes.people.values.flatMap { $0 })).sorted()
        // ⚠️ 既存カタログが「取れたが読めない」ときは**書かない**（レビュー指摘）。空から
        // 作り直すと、アルバム名・人物名・シャード一覧・アルバム ID 対応が丸ごと消える。
        // 書かなければ既存のシャードが再送キューへ戻り（呼び出し側）、次回また試行される。
        guard let catalog = BackupMetadataPlanning.updatedCatalog(
            existing: existing, touchedShards: touched,
            albums: albumNames, people: peopleNames, albumIDs: indexes.albumIDs,
            deviceID: BackupDeviceIdentity.currentID(),
            deviceName: BackupDeviceIdentity.currentDisplayName()) else {
            addLog("  catalog.json: skipped — existing file is not readable JSON")
            Diagnostics.mark("backup: catalog unreadable — \(path)")
            return false
        }
        let result = await uploader.uploadJSONResult(catalog, to: path, token: token)
        addLog("  catalog.json (shards=\(catalog.shards.count)): \(result.detail)")
        return result.ok
    }

    // MARK: - Helpers

    func setPhase(_ phase: BackupEngine.Phase) {
        delegate.runnerSetPhase(phase)
    }

    func addLog(_ message: String) {
        delegate.runnerLog(message)
    }

    private func fail(_ message: String) {
        addLog("FAILED: \(message)")
        setPhase(.failed(message))
    }
}
