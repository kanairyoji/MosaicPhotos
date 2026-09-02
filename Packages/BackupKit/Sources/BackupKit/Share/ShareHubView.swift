#if canImport(UIKit)
import SwiftUI

/// クラウド共有のハブ画面。**「受ける」と「提供する」は独立した機能**として
/// 別々のトグルで設定する（バックアップとも独立・ADR-112 追記）:
/// - 受ける: 共有されたフォルダの閲覧＋解析取り込み。Dropbox 接続だけで動く。
/// - 提供する: 共有セットの作成・反映。端末写真の共有のみバックアップが前提。
public struct ShareHubView: View {
    private let engine: ShareSyncEngine
    /// 家族フォルダ（受信側）の変更通知。アプリが同期ルート・取り込みへ反映する。
    private let onFamilyFoldersChanged: @MainActor () -> Void
    /// 「今すぐ取り込み」（受信側・サイドカー取り込み）。未設定なら非表示。
    private let onImportNow: (@MainActor () async -> Void)?

    @AppStorage(ShareSettingsKeys.receiveEnabled) private var receiveEnabled = true
    @AppStorage(ShareSettingsKeys.provideEnabled) private var provideEnabled = true
    @State private var familyFolders: [String] = ShareSettingsKeys.currentFamilyFolders()

    public init(engine: ShareSyncEngine,
                onFamilyFoldersChanged: @escaping @MainActor () -> Void = {},
                onImportNow: (@MainActor () async -> Void)? = nil) {
        self.engine = engine
        self.onFamilyFoldersChanged = onFamilyFoldersChanged
        self.onImportNow = onImportNow
    }

    public var body: some View {
        // 「受け取る」と「提供する」は**別の機能**。トップは 2 つの入り口だけにし、
        // それぞれ専用画面へ分ける（実フィードバック: 同一リスト内のセクション分けでは
        // 別機能だと伝わらない）。
        List {
            Section {
                NavigationLink {
                    ShareReceiveView(familyFolders: $familyFolders,
                                     onFamilyFoldersChanged: onFamilyFoldersChanged,
                                     onImportNow: onImportNow)
                } label: {
                    featureRow(icon: "icloud.and.arrow.down", tint: .green,
                               title: L("Receive Shared Albums"),
                               subtitle: L("View albums others shared with you"),
                               status: receiveStatus)
                }
            } footer: {
                Text(L("Works on its own — no backup and no sharing of your photos required. Only a Dropbox connection is needed."))
            }

            Section {
                NavigationLink {
                    ShareProvideView(engine: engine, onShareRootChanged: onFamilyFoldersChanged)
                } label: {
                    featureRow(icon: "icloud.and.arrow.up", tint: .blue,
                               title: L("Share Your Photos"),
                               subtitle: L("Copy selected photos into a shared folder"),
                               status: provideStatus)
                }
            } footer: {
                Text(L("Create shared sets from albums, people, and groups. Device photos need Backup to be shared (cloud photos don't). Receiving is not affected by this switch."))
            }
        }
        .navigationTitle(L("Cloud Sharing"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await engine.refresh() }
    }

    // MARK: - 入り口の行（機能アイコン＋状態）

    private var receiveStatus: String {
        guard receiveEnabled else { return L("Off") }
        let count = familyFolders.count
        return count > 0 ? String(format: L("%d folders"), count) : L("On")
    }

    private var provideStatus: String {
        guard provideEnabled else { return L("Off") }
        let count = engine.sets.count
        return count > 0 ? String(format: L("%d sets"), count) : L("On")
    }

    private func featureRow(icon: String, tint: Color, title: String,
                            subtitle: String, status: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

}


/// 提供専用画面（トグル＋共有セット＋反映＋共有ルート）。独立機能（ADR-112 追記）。
struct ShareProvideView: View {
    let engine: ShareSyncEngine
    /// 共有ルートを変えたときに、表示の除外パスを更新してもらうための通知。
    var onShareRootChanged: @MainActor () -> Void = {}

    @AppStorage(ShareSettingsKeys.provideEnabled) private var provideEnabled = true
    @AppStorage(ShareSettingsKeys.shareNamesEnabled) private var shareNames = true
    @AppStorage(ShareSettingsKeys.shareRootFolder)
    private var shareRoot = ShareSettingsKeys.defaultShareRootFolder
    @AppStorage(BackupSettingsKeys.destination)
    private var backupDestination: BackupDestination = .disabled

    var body: some View {
        List {
            Section {
                Toggle(L("Share Your Photos"), isOn: $provideEnabled)
            } footer: {
                Text(L("Create shared sets from albums, people, and groups. Device photos need Backup to be shared (cloud photos don't). Receiving is not affected by this switch."))
            }
            if provideEnabled {
                Section {
                    Toggle(L("Include People Names"), isOn: $shareNames)
                } footer: {
                    Text(L("Shares the names you gave to people, so the same person is already named on your family's devices. Faces are always shared (that is how people are grouped) — this only controls the names. Turning it off does not remove names already shared."))
                }
                setsSection
                syncSection
                shareRootSection
            }
        }
        .navigationTitle(L("Share Your Photos"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await engine.refresh() }
    }

    // MARK: - 共有セット

    private var setsSection: some View {
        Section {
            if engine.sets.isEmpty {
                Text(L("No shared sets yet. Open an album and choose “Cloud Share…” to create one."))
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
                Label(Self.message(for: error), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            // 端末写真の共有はバックアップ実体からのコピーなので、バックアップ前は進まない。
            // 原因をその場で案内する（実フィードバック: 案内が無いと「動かない」ように見える）。
            if engine.sets.contains(where: { $0.waitingBackup > 0 }) {
                if backupDestination == .disabled {
                    Label(L("Device photos can be shared only after they are backed up. Turn on Backup in Settings to share them (cloud photos are shared without backup)."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                } else {
                    Label(L("Some photos are not backed up yet. They are prioritized in the next backup and will be shared right after."),
                          systemImage: "clock")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        } footer: {
            Text(L("Sets also sync automatically after each backup. Copies are made on the Dropbox server, so no photo data is re-uploaded."))
        }
    }

    // MARK: - 共有ルート（送信側）

    /// 失敗種別 → 表示文言（翻訳対象）。
    static func message(for error: ShareSyncEngine.SyncError) -> String {
        switch error {
        case .notConnected:        return L("Not connected to Dropbox.")
        case .folderPrepareFailed: return L("Could not prepare the shared folder.")
        case .folderCheckFailed:   return L("Could not check the shared folder.")
        case .folderRemoveFailed:  return L("Could not remove the shared folder.")
        case .invalidFolderName:   return L("This set has an invalid folder name.")
        case .syncBusy:            return L("Syncing is still running. Try again in a moment.")
        }
    }

    private var shareRootSection: some View {
        Section {
            TextField(L("Shared folder"), text: $shareRoot)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                // ルートを変えたら表示の除外パスも更新する（変えないと旧ルートが隠れたまま・
                // 新ルートが Cloud/All に二重表示される）。家族フォルダ変更と同じ経路を叩く。
                .onChange(of: shareRoot) { _, _ in onShareRootChanged() }
        } header: {
            Text(L("Shared Folder (yours)"))
        } footer: {
            Text(L("Share this folder with others in the Dropbox app (inviting them as view-only is recommended). Sets are created inside it."))
        }
    }
}

/// 受け取り専用画面（トグル＋共有されたフォルダ＋取り込み）。独立機能（ADR-112 追記）。
struct ShareReceiveView: View {
    @Binding var familyFolders: [String]
    let onFamilyFoldersChanged: @MainActor () -> Void
    let onImportNow: (@MainActor () async -> Void)?

    @AppStorage(ShareSettingsKeys.receiveEnabled) private var receiveEnabled = true
    @State private var newFamilyFolder = ""
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                Toggle(L("Receive Shared Albums"), isOn: $receiveEnabled)
                    .onChange(of: receiveEnabled) { _, _ in onFamilyFoldersChanged() }
            } footer: {
                Text(L("Works on its own — no backup and no sharing of your photos required. Only a Dropbox connection is needed."))
            }
            if receiveEnabled {
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
        .navigationTitle(L("Receive Shared Albums"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// セット詳細（メンバー一覧・単枚解除・セット削除）。
struct ShareSetDetailView: View {
    let engine: ShareSyncEngine
    let setID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ShareItemLite] = []
    @State private var confirmingDelete = false
    @State private var canRefresh = false
    @State private var isRefreshing = false

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
                if canRefresh {
                    Button {
                        isRefreshing = true
                        Task {
                            await engine.refreshFromSource(setID: setID)
                            await reload()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            HStack { ProgressView(); Text(L("Updating…")) }
                        } else {
                            Text(L("Update to Current Contents"))
                        }
                    }
                    .disabled(isRefreshing)
                }
            } footer: {
                if canRefresh {
                    Text(L("A shared set keeps the photos it had when you created it. Use this to match it to the album or person as it is now (photos removed from the source are also removed from the shared folder)."))
                } else {
                    Text(L("The album or person this set came from no longer exists, so it can't be updated automatically. The shared photos stay until you delete the set."))
                }
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
        if let summary { canRefresh = await engine.canRefreshFromSource(summary) }
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
