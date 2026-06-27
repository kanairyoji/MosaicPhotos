#if canImport(UIKit)
import DropboxCore
import PhotoSourceKit
import SwiftUI

/// Dropbox の通常設定：接続・サムネイル並列数・キャッシュ上限。
/// 詳細な診断（トークン・キャッシュ状態・消去/再同期・チューニング定数）は `DropboxDebugSection` に分離し、
/// app の Developer Options 画面が合成する。
public struct DropboxSettingsView: View {
    let dropboxAuth: DropboxAuthService
    /// バックグラウンド同期状態の表示に使用するストア（省略可）。
    let store: DropboxPhotoStore?
    @AppStorage(DropboxCacheSettingsKeys.thumbnailLimitMB) private var dropboxThumbLimitMB     = 50
    @AppStorage(DropboxCacheSettingsKeys.fullImageLimitMB) private var dropboxFullImageLimitMB = 200
    @AppStorage(DropboxCacheSettingsKeys.thumbnailConcurrency)
    private var thumbnailConcurrency = DropboxThumbnailSettings.defaultConcurrency

    public init(dropboxAuth: DropboxAuthService, store: DropboxPhotoStore? = nil) {
        self.dropboxAuth = dropboxAuth
        self.store = store
    }

    public var body: some View {
        Group {
            dropboxConnectionSection
            performanceSection
            cacheLimitsSection
        }
        // Use onAppear (not .task) so the values always re-apply when the user
        // navigates back to the Settings tab, not just on first appearance.
        .onAppear {
            // DropboxCacheStore は UserDefaults を読まないため、
            // 設定タブの表示時に保存済みの値を実行中のキャッシュへ反映する。
            Task { await store?.applyCacheLimits(thumbnailMB: dropboxThumbLimitMB, fullImageMB: dropboxFullImageLimitMB) }
            store?.applyThumbnailConcurrency(thumbnailConcurrency)
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

    // MARK: - Helpers

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow
    }
}

#endif
