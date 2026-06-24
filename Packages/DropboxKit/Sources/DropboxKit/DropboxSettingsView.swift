#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

public struct DropboxSettingsView: View {
    let dropboxAuth: DropboxAuthService
    /// バックグラウンド同期状態の表示に使用するストア（省略可）。
    let store: DropboxPhotoStore?
    @AppStorage(DropboxCacheSettingsKeys.thumbnailLimitMB) private var dropboxThumbLimitMB     = 50
    @AppStorage(DropboxCacheSettingsKeys.fullImageLimitMB) private var dropboxFullImageLimitMB = 200
    @AppStorage(DropboxCacheSettingsKeys.thumbnailConcurrency)
    private var thumbnailConcurrency = DropboxThumbnailSettings.defaultConcurrency
    @State private var directTokenInput = ""
    @State private var cacheDebugModel = DropboxCacheDebugModel()
    @State private var showClearCacheConfirmation = false

    public init(dropboxAuth: DropboxAuthService, store: DropboxPhotoStore? = nil) {
        self.dropboxAuth = dropboxAuth
        self.store = store
    }

    public var body: some View {
        Group {
            dropboxConnectionSection
            dropboxDebugSection
            performanceSection
            cacheLimitsSection
            cacheStatusSection
            tuningConstantsSection
        }
        // Use onAppear (not .task) so the stats always refresh when the user
        // navigates back to the Settings tab, not just on first appearance.
        .onAppear {
            cacheDebugModel.refresh()
            // DropboxCacheStore は UserDefaults を読まないため、
            // 設定タブの表示時に保存済みの値を実行中のキャッシュへ反映する。
            Task { await store?.applyCacheLimits(thumbnailMB: dropboxThumbLimitMB, fullImageMB: dropboxFullImageLimitMB) }
            store?.applyThumbnailConcurrency(thumbnailConcurrency)
        }
    }

    // MARK: - Performance section

    private var performanceSection: some View {
        Section {
            Stepper(value: $thumbnailConcurrency,
                    in: DropboxThumbnailSettings.minConcurrency...DropboxThumbnailSettings.maxConcurrency) {
                LabeledContent("Parallel downloads", value: "\(thumbnailConcurrency)")
            }
            .onChange(of: thumbnailConcurrency) { _, newValue in
                store?.applyThumbnailConcurrency(newValue)
            }
        } header: {
            Text("Thumbnail Performance")
        } footer: {
            Text("How many thumbnail batches Dropbox fetches at once (\(DropboxThumbnailSettings.minConcurrency)–\(DropboxThumbnailSettings.maxConcurrency)). Higher is faster when many thumbnails are visible, but too high may hit Dropbox rate limits. Default is \(DropboxThumbnailSettings.defaultConcurrency).")
        }
    }

    // MARK: - Dropbox connection section

    private var dropboxConnectionSection: some View {
        Section("Dropbox") {
            HStack {
                Text("Status")
                Spacer()
                dropboxStatusBadge
            }

            if case .connected = dropboxAuth.connectionStatus,
               let connectedAt = dropboxAuth.credential?.connectedAt {
                LabeledContent("Connected", value: DisplayDate.dateTime(connectedAt))
            }

            dropboxActionButton
        }
    }

    @ViewBuilder
    private var dropboxStatusBadge: some View {
        switch dropboxAuth.connectionStatus {
        case .notConnected:
            Label("Not connected", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .authenticating:
            Label("Connecting...", systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.blue)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Label("Error", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var dropboxActionButton: some View {
        switch dropboxAuth.connectionStatus {
        case .notConnected, .error:
            Button("Connect to Dropbox") {
                Task {
                    guard let anchor = keyWindow else { return }
                    await dropboxAuth.authenticate(presentationAnchor: anchor)
                }
            }
        case .authenticating:
            Button("Cancel", role: .cancel) {
                dropboxAuth.cancelAuthentication()
            }
            .foregroundStyle(.secondary)
        case .connected:
            Button("Disconnect", role: .destructive) {
                dropboxAuth.disconnect()
            }
        }
    }

    // MARK: - Dropbox debug section

    private var dropboxDebugSection: some View {
        Section("Dropbox — Debug") {
            if let cred = dropboxAuth.credential {
                LabeledContent("Access token", value: masked(cred.accessToken))
                LabeledContent("Refresh token", value: cred.refreshToken != nil ? "Present" : "None")
                if let expiresAt = cred.expiresAt {
                    LabeledContent("Expires", value: DisplayDate.dateTime(expiresAt))
                }
                if let lastRefreshed = cred.lastRefreshedAt {
                    LabeledContent("Last refreshed", value: DisplayDate.dateTime(lastRefreshed))
                }
                if let accountId = cred.accountId {
                    LabeledContent("Account ID", value: accountId)
                }
            }
            if case .error(let msg) = dropboxAuth.connectionStatus {
                LabeledContent("Error detail", value: msg)
                if let e = dropboxAuth.lastError {
                    LabeledContent("Error date", value: DisplayDate.dateTime(e.date))
                }
            }

            TextField("Enter access token directly", text: $directTokenInput)
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Apply") {
                let token = directTokenInput.trimmingCharacters(in: .whitespaces)
                directTokenInput = ""
                Task {
                    await dropboxAuth.setDirectToken(token)
                }
            }
            .disabled(
                directTokenInput.trimmingCharacters(in: .whitespaces).isEmpty
                    || dropboxAuth.connectionStatus == .authenticating
            )
        }
    }

    // MARK: - Cache limits section

    private var cacheLimitsSection: some View {
        Section("Cache Limits") {
            Picker("Thumbnail limit", selection: $dropboxThumbLimitMB) {
                Text("25 MB").tag(25)
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
            }
            .onChange(of: dropboxThumbLimitMB) { _, newVal in
                Task { await store?.applyCacheLimits(thumbnailMB: newVal, fullImageMB: dropboxFullImageLimitMB) }
            }
            Picker("Full image limit", selection: $dropboxFullImageLimitMB) {
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
            }
            .onChange(of: dropboxFullImageLimitMB) { _, newVal in
                Task { await store?.applyCacheLimits(thumbnailMB: dropboxThumbLimitMB, fullImageMB: newVal) }
            }
        }
    }

    // MARK: - Cache status section

    private var cacheStatusSection: some View {
        Section("Cache Status") {
            if let store {
                LabeledContent("Sync", value: syncStateLabel(store.syncState))
            }
            if let s = cacheDebugModel.stats {
                LabeledContent("Files in DB", value: "\(s.itemCount)")
                LabeledContent("Thumbnails", value: "\(s.thumbnailCount) · \(formatBytes(s.thumbnailBytes))")
                LabeledContent("Full images", value: "\(s.fullImageCount) · \(formatBytes(s.fullImageBytes))")
                if let d = s.lastSyncedAt {
                    LabeledContent("Last synced", value: DisplayDate.dateTime(d))
                }
            } else {
                Text("Not loaded")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Refresh") {
                    cacheDebugModel.refresh()
                }
                Spacer()
                NavigationLink("View contents") {
                    DropboxCacheListView(model: cacheDebugModel)
                }
            }
            if let store {
                Button("Force Re-sync") { store.forceResync() }
            }
            Button("Clear Dropbox Cache", role: .destructive) {
                showClearCacheConfirmation = true
            }
            .alert("Clear Dropbox Cache?", isPresented: $showClearCacheConfirmation) {
                Button("Clear", role: .destructive) {
                    Task {
                        // 動作中ストア経由で消去＋再同期する（cursor/syncState もリセットされ、
                        // 消去後に空のまま再同期されない問題を防ぐ）。store が無い場合のみ単独消去。
                        if let store {
                            await store.clearCache()
                        } else {
                            cacheDebugModel.clearAll()
                        }
                        cacheDebugModel.refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All cached metadata and files will be deleted. This cannot be undone.")
            }
        }
    }

    // MARK: - Tuning constants (debug, read-only)

    private var tuningConstantsSection: some View {
        Section("Debug — Tuning Constants") {
            let c = DropboxDebugConstants.self
            LabeledContent("Token refresh buffer", value: "\(c.tokenExpiryBufferSeconds) s")
            LabeledContent("Thumbnail batch size", value: "\(c.thumbnailBatchChunkSize)")
            LabeledContent("Thumbnail batch debounce", value: "\(c.thumbnailBatchDebounceMs) ms")
            LabeledContent("Thumbnail API size", value: c.thumbnailAPISize)
            LabeledContent("list_folder page limit", value: "\(c.listFolderPageLimit)")
            LabeledContent("Parallel folder scans", value: "\(c.parallelFolderScanBatchSize)")
            LabeledContent("Longpoll timeout", value: "\(c.longpollTimeoutSeconds) s")
            LabeledContent("Retry delay", value: "\(c.retryDelaySeconds) s")
            LabeledContent("JPEG quality (thumb/full)", value: "\(c.thumbnailJPEGQuality) / \(c.fullImageJPEGQuality)")
            LabeledContent("Default limits (thumb/full)", value: "\(c.defaultThumbnailLimitMB) MB / \(c.defaultFullImageLimitMB) MB")
            LabeledContent("PKCE verifier bytes", value: "\(c.pkceVerifierByteCount)")
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow
    }

    private func masked(_ token: String) -> String {
        String(token.prefix(8)) + "..."
    }

    private func syncStateLabel(_ state: DropboxPhotoStore.SyncState) -> String {
        switch state {
        case .idle:                    return "Idle"
        case .initialSync(let n):      return "Initial sync · \(n) photos"
        case .polling:                 return "Watching for changes"
        case .fetchingDelta:           return "Fetching changes…"
        case .error(let msg):          return "Error: \(msg)"
        }
    }
}
#endif
