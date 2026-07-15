#if canImport(UIKit)
import DropboxCore
import Photos
import SwiftUI

// MARK: - Debug section (Developer Options)

/// バックアップの詳細診断：進捗・フォルダ確認・ローカル/メタデータ統計・ログ。
/// app の Developer Options 画面が合成して表示する（既定では非表示）。
/// 通常設定は `BackupSettingsView` に分離している（`backupNormalizedPath` は同モジュールで共有）。
public struct BackupDebugSection: View {
    let dropboxAuth: DropboxAuthService
    let engine: BackupEngine
    let dropboxStore: DropboxPhotoStore?

    @AppStorage(BackupSettingsKeys.dropboxFolder) private var dropboxFolder = BackupSettingsKeys.defaultDropboxFolder
    @State private var folderCheckState: FolderCheckState = .idle
    @State private var localStats: LocalStats?

    public init(dropboxAuth: DropboxAuthService, engine: BackupEngine, dropboxStore: DropboxPhotoStore? = nil) {
        self.dropboxAuth  = dropboxAuth
        self.engine       = engine
        self.dropboxStore = dropboxStore
    }

    public var body: some View {
        Group {
            progressDebugSection
            offloadGateSection
            debugControlSection
            debugLocalRecordsSection
            debugLocalStatsSection
            debugMetadataStatsSection
            debugLogSection
        }
        .task {
            localStats = await Task.detached { computeLocalStats() }.value
        }
    }

    // MARK: - Debug: progress

    /// オフロード実削除のゲート（ADR-40 の段階導入）。既定 OFF＝ドライランのみ。
    private var offloadGateSection: some View {
        Section {
            Toggle("Offload: allow real deletion",
                   isOn: Binding(
                       get: { UserDefaults.standard.bool(forKey: BackupSettingsKeys.offloadRealDeletionEnabled) },
                       set: { UserDefaults.standard.set($0, forKey: BackupSettingsKeys.offloadRealDeletionEnabled) }))
        } footer: {
            Text("OFF (default): Offload screen is dry-run only. ON: the delete button appears — deletion still requires the system confirmation dialog and stays in Recently Deleted for 30 days.")
        }
    }

    @State private var reconcileResult: String?
    @State private var isReconciling = false

    private var progressDebugSection: some View {
        Section {
            LabeledContent("Backup records", value: "\(engine.recordCount)")
            LabeledContent("Uploaded IDs", value: "\(engine.uploadedIDCount)")
            LabeledContent("Metadata path", value: BackupEngine.metadataPathSuffix)
            // Dropbox の実ファイル一覧（list_folder・再帰）と記録/台帳を照合して実態に合わせる。
            // 「Dropbox 側でファイルを消した」「409 誤記録時代の済み ID」をここで一掃できる。
            Button {
                isReconciling = true
                Task {
                    if let r = await engine.reconcileWithDropbox() {
                        reconcileResult = "verified \(r.verified), removed \(r.removed) stale, remote files \(r.remoteFiles)"
                    } else {
                        reconcileResult = "failed (auth or network)"
                    }
                    isReconciling = false
                }
            } label: {
                if isReconciling {
                    HStack { ProgressView().controlSize(.small); Text("Reconciling…") }
                } else {
                    Text("Reconcile with Dropbox (verify records)")
                }
            }
            .disabled(isReconciling || engine.isRunning)
            if let reconcileResult {
                Text(reconcileResult).font(.caption).foregroundStyle(.secondary)
            }
            // 台帳（UserDefaults）だけでなく SwiftData 記録も消す全消去。
            // ⚠️ 台帳のみのクリアは、済み判定が「台帳 ∪ 記録」になったため見かけ上効かない。
            Button("Clear ALL Backup Records (progress + records)", role: .destructive) {
                Task { await engine.clearAllBackupRecords() }
                reconcileResult = nil
            }
            .disabled(engine.isRunning)
        } header: {
            Text("Backup — Progress")
        } footer: {
            Text("Reconcile lists actual files on Dropbox and drops records whose file is missing or has a different content hash. Clear ALL wipes progress and records; the next backup re-verifies existing files via 409 + hash without re-uploading.")
        }
    }

    // MARK: - Debug: folder check

    private var debugControlSection: some View {
        Section("Backup — Folder Check") {
            HStack {
                Button {
                    Task { await checkFolder() }
                } label: {
                    if folderCheckState == .checking {
                        ProgressView().controlSize(.small).padding(.trailing, 4)
                        Text("Checking…")
                    } else {
                        Label("Check Folder", systemImage: "arrow.clockwise.circle")
                    }
                }
                .disabled(
                    folderCheckState == .checking
                        || dropboxAuth.connectionStatus != .connected
                )

                Spacer()

                folderCheckResultView
            }
        }
    }

    @ViewBuilder
    private var folderCheckResultView: some View {
        switch folderCheckState {
        case .idle, .checking:
            EmptyView()
        case .found:
            Label("Folder found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .notFound:
            Label("Not found — will be created", systemImage: "folder.badge.plus")
                .foregroundStyle(.orange).font(.callout)
        case .isFile:
            Label("Path is a file, not a folder", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }

    // MARK: - Debug: SwiftData backup records

    private var debugLocalRecordsSection: some View {
        Section("Backup — Records (Local DB)") {
            if engine.isAlbumsLoaded {
                statRow("Backed-up photos", value: engine.recordCount, icon: "photo.on.rectangle")
                statRow("Albums collected", value: engine.albumInfos.count, icon: "rectangle.stack")
                if engine.recordCount == 0 {
                    Text("No records yet. Run a backup first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if engine.albumInfos.isEmpty {
                    Text("Photos backed up but none belong to a user-created album.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    // MARK: - Debug: local Photos library stats

    @ViewBuilder
    private var debugLocalStatsSection: some View {
        Section("Backup — Local Library") {
            if let s = localStats {
                statRow("People",    value: s.peopleCount,    icon: "person.2")
                statRow("Albums",    value: s.albumsCount,    icon: "rectangle.stack")
                statRow("Favorites", value: s.favoritesCount, icon: "heart")
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary).font(.callout)
                }
            }
        }
    }

    // MARK: - Debug: backup metadata stats

    @ViewBuilder
    private var debugMetadataStatsSection: some View {
        Section("Backup — Metadata") {
            if let meta = dropboxStore?.backupMetadata {
                let stats = MetadataStats(from: meta)
                statRow("Backed-up entries", value: stats.entries,   icon: "photo.on.rectangle")
                statRow("Unique people",     value: stats.people,    icon: "person.2")
                statRow("Unique albums",     value: stats.albums,    icon: "rectangle.stack")
                statRow("Favorites",         value: stats.favorites, icon: "heart")
            } else {
                Text("No backup metadata loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Debug: backup log

    @ViewBuilder
    private var debugLogSection: some View {
        if !engine.log.isEmpty {
            Section("Backup — Log") {
                ForEach(engine.log.reversed()) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.time)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        Text(entry.message)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func statRow(_ label: String, value: Int, icon: String) -> some View {
        LabeledContent {
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(value == 0 ? .secondary : .primary)
        } label: {
            Label(label, systemImage: icon)
        }
    }

    // MARK: - Folder check

    private enum FolderCheckState: Equatable {
        case idle, checking, found, notFound, isFile
        case error(String)
    }

    private func checkFolder() async {
        folderCheckState = .checking
        let path = backupNormalizedPath(dropboxFolder)
        if path != dropboxFolder { dropboxFolder = path }

        do {
            let token = try await dropboxAuth.freshAccessToken()

            struct Body: Encodable { let path: String }
            struct Meta: Decodable {
                let tag: String
                enum CodingKeys: String, CodingKey { case tag = ".tag" }
            }

            var req = URLRequest(
                url: URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(Body(path: path))

            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            switch status {
            case 200:
                let meta = try? JSONDecoder().decode(Meta.self, from: data)
                switch meta?.tag {
                case "folder": folderCheckState = .found
                case "file":   folderCheckState = .isFile
                default:       folderCheckState = .notFound
                }
            case 409:
                folderCheckState = .notFound
            default:
                folderCheckState = .error("HTTP \(status)")
            }
        } catch {
            folderCheckState = .error(error.localizedDescription)
        }
    }
}

// MARK: - Local stats

private struct LocalStats {
    let peopleCount: Int
    let albumsCount: Int
    let favoritesCount: Int
}

private func computeLocalStats() -> LocalStats {
    let facesSubtype = PHAssetCollectionSubtype(rawValue: 1000) // albumFaces
    let peopleCount = facesSubtype.map {
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: $0, options: nil).count
    } ?? 0

    let albumsCount = PHAssetCollection.fetchAssetCollections(
        with: .album, subtype: .albumRegular, options: nil).count

    let favOpts = PHFetchOptions()
    favOpts.predicate = NSPredicate(
        format: "isFavorite == YES AND mediaType == %d", PHAssetMediaType.image.rawValue)
    let favoritesCount = PHAsset.fetchAssets(with: favOpts).count

    return LocalStats(
        peopleCount: peopleCount,
        albumsCount: albumsCount,
        favoritesCount: favoritesCount
    )
}

// MARK: - Metadata stats

private struct MetadataStats {
    let entries: Int
    let people: Int
    let albums: Int
    let favorites: Int

    init(from meta: DropboxBackupMetadata) {
        entries   = meta.entries.count
        people    = Set(meta.entries.values.flatMap { $0.people }).count
        albums    = Set(meta.entries.values.flatMap { $0.albums }).count
        favorites = meta.entries.values.filter { $0.isFavorite }.count
    }
}
#endif
