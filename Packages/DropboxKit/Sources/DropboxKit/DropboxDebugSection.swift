#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

// MARK: - Debug section (Developer Options)

/// Dropbox の詳細診断：認証トークン・キャッシュ状態・消去/再同期・チューニング定数・直接トークン投入。
/// app の Developer Options 画面が合成して表示する（既定では非表示）。
/// 通常設定は `DropboxSettingsView` に分離している。
public struct DropboxDebugSection: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    @State private var directTokenInput = ""
    @State private var cacheDebugModel = DropboxCacheDebugModel()
    @State private var showClearCacheConfirmation = false

    public init(dropboxAuth: DropboxAuthService, store: DropboxPhotoStore? = nil) {
        self.dropboxAuth = dropboxAuth
        self.store = store
    }

    public var body: some View {
        Group {
            authDebugSection
            cacheStatusSection
            tuningConstantsSection
        }
        .task { await cacheDebugModel.refresh(store: store) }
    }

    // MARK: - Auth debug

    private var authDebugSection: some View {
        Section("Dropbox — Auth") {
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
                    Task { await cacheDebugModel.refresh(store: store) }
                }
                Spacer()
                NavigationLink("View contents") {
                    DropboxCacheListView(model: cacheDebugModel, store: store)
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
                    // 動作中ストア経由で消去＋再同期（cursor/syncState もリセット）→ 再取得。
                    Task { await cacheDebugModel.clearAll(store: store) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All cached metadata and files will be deleted. This cannot be undone.")
            }
        }
    }

    // MARK: - Tuning constants (read-only)

    private var tuningConstantsSection: some View {
        Section("Dropbox — Tuning Constants") {
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

    // formatBytes は PhotoSourceKit の共通ヘルパへ集約。

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
