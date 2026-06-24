#if canImport(UIKit)
import DropboxCore
import Photos
import SwiftUI

/// バックアップ設定セクション。SettingsView の "Backup" タブに配置する。
public struct BackupSettingsView: View {
    let dropboxAuth: DropboxAuthService
    let engine: BackupEngine
    let dropboxStore: DropboxPhotoStore?

    @AppStorage(BackupSettingsKeys.destination) private var destination: BackupDestination = .disabled
    @AppStorage(BackupSettingsKeys.dropboxFolder) private var dropboxFolder = "/MosaicPhotos"
    @AppStorage(BackupSettingsKeys.uploadLimit) private var uploadLimit = 10
    @State private var folderCheckState: FolderCheckState = .idle
    @State private var localStats: LocalStats?

    public init(dropboxAuth: DropboxAuthService, engine: BackupEngine, dropboxStore: DropboxPhotoStore? = nil) {
        self.dropboxAuth  = dropboxAuth
        self.engine       = engine
        self.dropboxStore = dropboxStore
    }

    public var body: some View {
        Group {
            Section("Backup Destination") {
                Picker("Destination", selection: $destination) {
                    Text("No backup").tag(BackupDestination.disabled)
                    Text("Dropbox").tag(BackupDestination.dropbox)
                }
            }

            if destination == .dropbox {
                dropboxFolderSection
                uploadLimitSection
                backupSection
                progressDebugSection
                debugControlSection
                debugLocalRecordsSection
                debugLocalStatsSection
                debugMetadataStatsSection
                debugLogSection
            }
        }
        .onChange(of: engine.phase) { _, newPhase in
            if case .completed = newPhase, let store = dropboxStore {
                Task { await store.loadBackupMetadata(from: normalizedPath(dropboxFolder)) }
            }
        }
        .task(id: destination) {
            guard destination == .dropbox else { return }
            localStats = await Task.detached { computeLocalStats() }.value
        }
    }

    // MARK: - Dropbox folder

    private var dropboxFolderSection: some View {
        Section("Dropbox Folder") {
            if dropboxAuth.connectionStatus != .connected {
                Label(
                    "Dropbox is not connected. Go to the Dropbox tab to connect.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            LabeledContent("Folder") {
                TextField("/MosaicPhotos", text: $dropboxFolder)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: dropboxFolder) { _, _ in
                        folderCheckState = .idle
                    }
            }

            Text("Photos will be backed up to this folder in your Dropbox. The folder will be created if it doesn't exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Backup controls

    private var backupSection: some View {
        Section("Backup") {
            if engine.isRunning {
                Button("Cancel Backup", role: .destructive) { engine.cancel() }
            } else {
                Button("Back Up Now") {
                    engine.start(folder: normalizedPath(dropboxFolder))
                }
                .disabled(dropboxAuth.connectionStatus != .connected)
            }

            backupPhaseView
        }
    }

    @ViewBuilder
    private var backupPhaseView: some View {
        switch engine.phase {
        case .idle:
            EmptyView()

        case .requestingPermission:
            Label("Requesting photo library access…", systemImage: "lock.open")
                .foregroundStyle(.secondary)

        case .buildingPeopleIndex:
            Label("Reading albums and people…", systemImage: "rectangle.stack.person.crop")
                .foregroundStyle(.secondary)

        case .fetchingAssets:
            Label("Loading photo library…", systemImage: "photo.stack")
                .foregroundStyle(.secondary)

        case .uploadingMetadata:
            Label("Saving metadata…", systemImage: "arrow.up.doc")
                .foregroundStyle(.secondary)

        case .uploading(let current, let total, let filename):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(current), total: Double(total))
                Text("Uploading \(current) of \(total)")
                    .font(.subheadline)
                Text(filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 2)

        case .completed(let uploaded, let skipped):
            Label(
                "\(uploaded) uploaded · \(skipped) already backed up",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)

        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)

        case .cancelled:
            Label("Backup cancelled.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Upload limit (user)

    private var uploadLimitSection: some View {
        Section("Upload Limit") {
            Picker("Per run", selection: $uploadLimit) {
                Text("10").tag(10)
                Text("50").tag(50)
                Text("100").tag(100)
                Text("500").tag(500)
                Text("Unlimited").tag(0)
            }
            Text("Maximum number of photos uploaded in a single backup run.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Debug: progress

    private var progressDebugSection: some View {
        Section("Debug — Progress") {
            LabeledContent("Backup records", value: "\(engine.recordCount)")
            LabeledContent("Uploaded IDs", value: "\(engine.uploadedIDCount)")
            LabeledContent("Metadata path", value: BackupEngine.metadataPathSuffix)
            Button("Clear Upload Progress", role: .destructive) {
                engine.clearUploadProgress()
            }
        }
    }

    // MARK: - Debug: folder check

    private var debugControlSection: some View {
        Section("Debug") {
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
        Section("Debug — Backup Records (Local DB)") {
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
        Section("Debug — Local Library") {
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
        Section("Debug — Backup Metadata") {
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
            Section("Debug — Backup Log") {
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
        let path = normalizedPath(dropboxFolder)
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

    // MARK: - Helpers

    private func normalizedPath(_ path: String) -> String {
        var s = path.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "/" }
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
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
