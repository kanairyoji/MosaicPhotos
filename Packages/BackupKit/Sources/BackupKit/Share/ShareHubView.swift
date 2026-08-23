#if canImport(UIKit)
import SwiftUI

/// 家族共有のハブ画面（共有セット一覧・反映・共有ルート・家族フォルダ）。
/// `DropboxHubView`（アプリ）から遷移する。セット作成はアルバム画面の
/// 「Share with Family…」から行う（ここは管理と受信設定）。
public struct ShareHubView: View {
    private let engine: ShareSyncEngine
    /// 家族フォルダ（受信側）の変更通知。アプリが同期ルート・取り込みへ反映する。
    private let onFamilyFoldersChanged: @MainActor () -> Void
    /// 「今すぐ取り込み」（受信側・サイドカー取り込み）。未設定なら非表示。
    private let onImportNow: (@MainActor () async -> Void)?

    @AppStorage(ShareSettingsKeys.shareRootFolder)
    private var shareRoot = ShareSettingsKeys.defaultShareRootFolder
    @State private var familyFolders: [String] = ShareSettingsKeys.currentFamilyFolders()
    @State private var newFamilyFolder = ""
    @State private var isImporting = false

    public init(engine: ShareSyncEngine,
                onFamilyFoldersChanged: @escaping @MainActor () -> Void = {},
                onImportNow: (@MainActor () async -> Void)? = nil) {
        self.engine = engine
        self.onFamilyFoldersChanged = onFamilyFoldersChanged
        self.onImportNow = onImportNow
    }

    public var body: some View {
        List {
            setsSection
            syncSection
            shareRootSection
            familySection
        }
        .navigationTitle(L("Sharing"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await engine.refresh() }
    }

    // MARK: - 共有セット

    private var setsSection: some View {
        Section {
            if engine.sets.isEmpty {
                Text(L("No shared sets yet. Open an album and choose “Share…” to create one."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(engine.sets) { set in
                NavigationLink {
                    ShareSetDetailView(engine: engine, setID: set.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name)
                        Text(statusLine(for: set))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L("Shared Sets"))
        } footer: {
            Text(L("Selected photos are copied into the shared folder. Originals and backups are never touched."))
        }
    }

    private func statusLine(for set: ShareSyncEngine.SetSummary) -> String {
        var parts = [String(format: L("%d photos"), set.total)]
        if set.copied < set.total {
            parts.append(String(format: L("%d shared"), set.copied))
        }
        if set.waitingBackup > 0 {
            parts.append(String(format: L("%d waiting for backup"), set.waitingBackup))
        }
        if set.failed > 0 {
            parts.append(String(format: L("%d failed"), set.failed))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 反映

    private var syncSection: some View {
        Section {
            Button {
                Task { await engine.syncNow() }
            } label: {
                if engine.isSyncing {
                    HStack {
                        ProgressView()
                        Text(L("Syncing…"))
                    }
                } else {
                    Text(L("Sync Now"))
                }
            }
            .disabled(engine.isSyncing || engine.sets.isEmpty)
            if let at = engine.lastSyncAt {
                LabeledContent(L("Last synced"), value: at.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = engine.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        } footer: {
            Text(L("Sets also sync automatically after each backup. Copies are made on the Dropbox server, so no photo data is re-uploaded."))
        }
    }

    // MARK: - 共有ルート（送信側）

    private var shareRootSection: some View {
        Section {
            TextField(L("Shared folder"), text: $shareRoot)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text(L("Shared Folder (yours)"))
        } footer: {
            Text(L("Share this folder with others in the Dropbox app (inviting them as view-only is recommended). Sets are created inside it."))
        }
    }

    // MARK: - 家族フォルダ（受信側）

    private var familySection: some View {
        Section {
            ForEach(familyFolders, id: \.self) { folder in
                Text(folder)
            }
            .onDelete { offsets in
                familyFolders.remove(atOffsets: offsets)
                ShareSettingsKeys.setFamilyFolders(familyFolders)
                onFamilyFoldersChanged()
            }
            HStack {
                TextField(L("Add folder path (e.g. /MosaicShare)"), text: $newFamilyFolder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L("Add")) {
                    let path = newFamilyFolder.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return }
                    familyFolders.append(path.hasPrefix("/") ? path : "/" + path)
                    ShareSettingsKeys.setFamilyFolders(familyFolders)
                    familyFolders = ShareSettingsKeys.currentFamilyFolders()
                    newFamilyFolder = ""
                    onFamilyFoldersChanged()
                }
                .disabled(newFamilyFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if onImportNow != nil, !familyFolders.isEmpty {
                Button {
                    guard let onImportNow else { return }
                    isImporting = true
                    Task {
                        await onImportNow()
                        isImporting = false
                    }
                } label: {
                    if isImporting {
                        HStack {
                            ProgressView()
                            Text(L("Importing…"))
                        }
                    } else {
                        Text(L("Import Shared Analysis Now"))
                    }
                }
                .disabled(isImporting)
            }
        } header: {
            Text(L("Folders Shared with You"))
        } footer: {
            Text(L("Folders others shared with you. Their photos appear in Cloud/All Photos, and shared AI analysis (tags, search, faces) is imported automatically so this device does not re-analyze them."))
        }
    }
}

/// セット詳細（メンバー一覧・単枚解除・セット削除）。
struct ShareSetDetailView: View {
    let engine: ShareSyncEngine
    let setID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ShareItemLite] = []
    @State private var confirmingDelete = false

    private var summary: ShareSyncEngine.SetSummary? {
        engine.sets.first { $0.id == setID }
    }

    var body: some View {
        List {
            Section {
                ForEach(items, id: \.refKey) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(for: item))
                                .lineLimit(1)
                            Text(stateLabel(for: item.state))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        stateIcon(for: item.state)
                    }
                }
                .onDelete { offsets in
                    let refKeys = offsets.map { items[$0].refKey }
                    Task {
                        await engine.removeItems(setID: setID, refKeys: refKeys)
                        await reload()
                    }
                }
            } footer: {
                Text(L("Swipe to remove a photo from this set (the copy in the shared folder is deleted; the original is kept)."))
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Text(L("Delete This Set"))
                }
            }
        }
        .navigationTitle(summary?.name ?? L("Shared Set"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .confirmationDialog(
            L("Delete this shared set? The folder is removed from the shared area, so people you share with will no longer see these photos. Copies they already saved cannot be removed. Originals and backups are kept."),
            isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button(L("Delete Set"), role: .destructive) {
                Task {
                    if await engine.deleteSet(id: setID) { dismiss() }
                }
            }
        }
    }

    private func reload() async {
        let store = await engine.storeForViews()
        items = await store.shareItems(setID: setID)
    }

    private func displayName(for item: ShareItemLite) -> String {
        if let path = item.sharedPath ?? item.sourcePath {
            return (path as NSString).lastPathComponent
        }
        if item.refKey.hasPrefix("C-") {
            return ((item.refKey as NSString).lastPathComponent)
        }
        return L("(waiting for backup)")
    }

    private func stateLabel(for state: ShareItemState) -> String {
        switch state {
        case .pending:       return L("Waiting to sync")
        case .waitingBackup: return L("Waiting for backup")
        case .copied:        return L("Shared")
        case .failed:        return L("Failed — will retry")
        }
    }

    @ViewBuilder
    private func stateIcon(for state: ShareItemState) -> some View {
        switch state {
        case .copied:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .pending, .waitingBackup:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}
#endif
