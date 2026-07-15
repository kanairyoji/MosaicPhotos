#if canImport(UIKit)
import DropboxCore
import Photos
import SwiftUI

/// バックアップの通常設定：宛先・Dropbox フォルダ・実行・アップロード上限。
/// 詳細な診断（進捗・フォルダ確認・ローカル/メタデータ統計・ログ）は `BackupDebugSection` に分離し、
/// app の Developer Options 画面が合成する。
public struct BackupSettingsView: View {
    let dropboxAuth: DropboxAuthService
    let engine: BackupEngine
    let dropboxStore: DropboxPhotoStore?

    @AppStorage(BackupSettingsKeys.destination) private var destination: BackupDestination = .disabled
    @AppStorage(BackupSettingsKeys.dropboxFolder) private var dropboxFolder = BackupSettingsKeys.defaultDropboxFolder
    @AppStorage(BackupSettingsKeys.uploadLimit) private var uploadLimit = 10
    /// バックアップ状況（対象総数・完了数）。表示時と完了時に更新する。
    @State private var status: (total: Int, done: Int)?

    public init(dropboxAuth: DropboxAuthService, engine: BackupEngine, dropboxStore: DropboxPhotoStore? = nil) {
        self.dropboxAuth  = dropboxAuth
        self.engine       = engine
        self.dropboxStore = dropboxStore
    }

    public var body: some View {
        Group {
            Section(L("Backup Destination")) {
                Picker(L("Destination"), selection: $destination) {
                    Text(L("No backup")).tag(BackupDestination.disabled)
                    Text(verbatim: "Dropbox").tag(BackupDestination.dropbox)
                }
            }

            if destination == .dropbox {
                dropboxFolderSection
                uploadLimitSection
                backupSection
                Section {
                    NavigationLink {
                        OffloadSettingsView(engine: engine)
                    } label: {
                        Label(L("Offload (free up device storage)"), systemImage: "externaldrive.badge.minus")
                    }
                } footer: {
                    Text(L("Preview which backed-up photos could be safely removed from this device."))
                }
            }
        }
        .onChange(of: engine.phase) { _, newPhase in
            if case .completed = newPhase {
                Task { status = await engine.backupStatus() }
                if let store = dropboxStore {
                    Task {
                        let root = backupNormalizedPath(dropboxFolder)
                        await store.loadBackupMetadata(from: [root, BackupEngine.deviceBackupRoot(for: root)])
                    }
                }
            }
        }
    }

    // MARK: - Dropbox folder

    private var dropboxFolderSection: some View {
        Section(L("Dropbox Folder")) {
            if dropboxAuth.connectionStatus != .connected {
                Label(
                    L("Dropbox is not connected. Connect from Settings → Dropbox."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            LabeledContent(L("Folder")) {
                TextField(BackupSettingsKeys.defaultDropboxFolder, text: $dropboxFolder)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Text(L("Photos will be backed up to this folder in your Dropbox. The folder will be created if it doesn't exist."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Backup controls

    private var backupSection: some View {
        Section(L("Backup")) {
            // バックアップ状況（総数・完了数・残数）。夜間自動バックアップ（ADR-42）の
            // 進み具合を、実行していないときでも確認できるようにする。
            if let status {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(L("Backed up"), systemImage: "checkmark.icloud")
                        Spacer()
                        Text(verbatim: "\(status.done) / \(status.total)")
                            .foregroundStyle(.secondary)
                    }
                    if status.total > status.done {
                        Text(String(format: L("%d photos remaining — runs automatically at night (charging, Wi-Fi)"),
                                    status.total - status.done))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if status.total > 0 {
                        Text(L("All photos are backed up."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack { ProgressView(); Text(L("Checking status…")).foregroundStyle(.secondary) }
            }

            if engine.isRunning {
                Button(L("Cancel Backup"), role: .destructive) { engine.cancel() }
            } else {
                Button(L("Back Up Now")) {
                    engine.start(folder: backupNormalizedPath(dropboxFolder))
                }
                .disabled(dropboxAuth.connectionStatus != .connected)
            }

            backupPhaseView
        }
        .task { status = await engine.backupStatus() }
    }

    @ViewBuilder
    private var backupPhaseView: some View {
        switch engine.phase {
        case .idle:
            EmptyView()

        case .requestingPermission:
            Label(L("Requesting photo library access…"), systemImage: "lock.open")
                .foregroundStyle(.secondary)

        case .buildingPeopleIndex:
            Label(L("Reading albums and people…"), systemImage: "rectangle.stack.person.crop")
                .foregroundStyle(.secondary)

        case .fetchingAssets:
            Label(L("Loading photo library…"), systemImage: "photo.stack")
                .foregroundStyle(.secondary)

        case .uploadingMetadata:
            Label(L("Saving metadata…"), systemImage: "arrow.up.doc")
                .foregroundStyle(.secondary)

        case .uploading(let current, let total, let filename):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(current), total: Double(total))
                Text(L("Uploading \(current) of \(total)"))
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
                L("\(uploaded) uploaded · \(skipped) already backed up"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)

        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)

        case .cancelled:
            Label(L("Backup cancelled."), systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Upload limit (user)

    private var uploadLimitSection: some View {
        Section(L("Upload Limit")) {
            Picker(L("Per run"), selection: $uploadLimit) {
                Text("10").tag(10)
                Text("50").tag(50)
                Text("100").tag(100)
                Text("500").tag(500)
                Text(L("Unlimited")).tag(0)
            }
            Text(L("Maximum number of photos uploaded in a single backup run."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
