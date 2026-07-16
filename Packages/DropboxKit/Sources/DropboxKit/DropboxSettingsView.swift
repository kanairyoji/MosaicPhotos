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
    @AppStorage(DropboxActivitySettingsKeys.showBar) private var showActivityBar = true

    public init(dropboxAuth: DropboxAuthService, store: DropboxPhotoStore? = nil) {
        self.dropboxAuth = dropboxAuth
        self.store = store
    }

    /// 読み込み対象フォルダの編集中テキスト（確定時に適用）。
    @State private var sourceFolderText = UserDefaults.standard.string(
        forKey: DropboxSourceSettings.sourceFolderKey) ?? "/"

    public var body: some View {
        Group {
            dropboxConnectionSection
            sourceFolderSection
            performanceSection
            activitySection
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

    // MARK: - Source folder (ADR-44)

    private var sourceFolderSection: some View {
        Section {
            TextField(L("Folder path (\u{201C}/\u{201D} = everything)"), text: $sourceFolderText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { applySourceFolder() }
            if normalizedPreview != DropboxSourceSettings.currentSourceFolder() {
                Button(L("Apply (resyncs the folder)")) { applySourceFolder() }
            }
        } header: {
            Text(L("Source Folder"))
        } footer: {
            Text(L("Only photos under this folder are shown and indexed. Default \u{201C}/\u{201D} covers your whole Dropbox. Your backup folder is always included. Changing the folder clears the cached listing and rescans."))
        }
    }

    private var normalizedPreview: String {
        DropboxSourceSettings.normalized(sourceFolderText)
    }

    private func applySourceFolder() {
        let normalized = DropboxSourceSettings.normalized(sourceFolderText)
        sourceFolderText = normalized.isEmpty ? "/" : normalized
        UserDefaults.standard.set(sourceFolderText, forKey: DropboxSourceSettings.sourceFolderKey)
        // 同期を再スタート（ルートが変わっていれば store 側のマーカー検知が
        // キャッシュ破棄→初回同期をやり直す）。
        store?.applySourceFolderChange()
    }

    // MARK: - Dropbox connection section

    private var dropboxConnectionSection: some View {
        Section("Dropbox") {
            HStack {
                Text(L("Status"))
                Spacer()
                dropboxStatusBadge
            }

            if case .connected = dropboxAuth.connectionStatus,
               let connectedAt = dropboxAuth.credential?.connectedAt {
                LabeledContent(L("Connected"), value: DisplayDate.dateTime(connectedAt))
            }

            dropboxActionButton
        }
    }

    @ViewBuilder
    private var dropboxStatusBadge: some View {
        switch dropboxAuth.connectionStatus {
        case .notConnected:
            Label(L("Not connected"), systemImage: "minus.circle")
                .foregroundStyle(.secondary)
        case .authenticating:
            Label(L("Connecting..."), systemImage: "arrow.trianglehead.2.clockwise")
                .foregroundStyle(.blue)
        case .connected:
            Label(L("Connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Label(L("Error"), systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var dropboxActionButton: some View {
        switch dropboxAuth.connectionStatus {
        case .notConnected, .error:
            Button(L("Connect to Dropbox")) {
                Task {
                    guard let anchor = keyWindow else { return }
                    await dropboxAuth.authenticate(presentationAnchor: anchor)
                }
            }
        case .authenticating:
            Button(L("Cancel"), role: .cancel) {
                dropboxAuth.cancelAuthentication()
            }
            .foregroundStyle(.secondary)
        case .connected:
            Button(L("Disconnect"), role: .destructive) {
                dropboxAuth.disconnect()
            }
        }
    }

    // MARK: - Performance section

    private var performanceSection: some View {
        Section {
            Stepper(value: $thumbnailConcurrency,
                    in: DropboxThumbnailSettings.minConcurrency...DropboxThumbnailSettings.maxConcurrency) {
                LabeledContent(L("Parallel downloads"), value: "\(thumbnailConcurrency)")
            }
            .onChange(of: thumbnailConcurrency) { _, newValue in
                store?.applyThumbnailConcurrency(newValue)
            }
        } header: {
            Text(L("Thumbnail Performance"))
        } footer: {
            Text(L("How many thumbnail batches Dropbox fetches at once (\(DropboxThumbnailSettings.minConcurrency)–\(DropboxThumbnailSettings.maxConcurrency)). Higher is faster when many thumbnails are visible, but too high may hit Dropbox rate limits. Default is \(DropboxThumbnailSettings.defaultConcurrency)."))
        }
    }

    // MARK: - Activity bar section

    private var activitySection: some View {
        Section {
            Toggle(L("Show activity bar"), isOn: $showActivityBar)
        } header: {
            Text(L("Activity Indicator"))
        } footer: {
            Text(L("Shows a small bar at the top of the screen with live Dropbox activity: parallel thumbnail download slots and the prefetch queue, plus sync, full-image download and backup upload. Useful to see when Dropbox is busy."))
        }
    }

    // MARK: - Cache limits section

    private var cacheLimitsSection: some View {
        Section(L("Cache Limits")) {
            Picker(L("Thumbnail limit"), selection: $dropboxThumbLimitMB) {
                Text("25 MB").tag(25)
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("200 MB").tag(200)
            }
            .onChange(of: dropboxThumbLimitMB) { _, newVal in
                Task { await store?.applyCacheLimits(thumbnailMB: newVal, fullImageMB: dropboxFullImageLimitMB) }
            }
            Picker(L("Full image limit"), selection: $dropboxFullImageLimitMB) {
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
