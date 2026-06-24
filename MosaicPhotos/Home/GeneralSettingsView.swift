import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 「General」タブ：アプリ情報・グリッド表示設定・Debug（アプリ情報詳細／ログ／全キャッシュ消去）。
struct GeneralSettingsView: View {
    let dropboxStore: DropboxPhotoStore?
    let placeScanner: PlaceScanner?

    // グリッドのズーム（列数）はサムネイル表示画面のスライダーで直接操作するため、設定側の項目は廃止。
    // LogChannel.verboseLoggingKey（MosaicSupport）と同一キー。app からは MosaicSupport を
    // 直接 import しないため文字列で指定する。
    @AppStorage("debug.verboseLogging") private var verboseLogging = true

    @State private var showClearAllConfirm = false
    @State private var isClearing = false

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"

    var body: some View {
        Group {
            Section("About") {
                LabeledContent("Version", value: version)
            }

            Section("Debug") {
                LabeledContent("Build", value: build)
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
                LabeledContent("Minimum iOS", value: "17.0")
                LabeledContent("Device", value: UIDevice.current.model)
                Toggle("Verbose logging", isOn: $verboseLogging)

                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    if isClearing {
                        HStack { ProgressView().controlSize(.small); Text("Clearing…") }
                    } else {
                        Text("Clear All Caches")
                    }
                }
                .disabled(isClearing)
                .confirmationDialog("Clear all caches?", isPresented: $showClearAllConfirm, titleVisibility: .visible) {
                    Button("Clear All", role: .destructive) { Task { await clearAll() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Photo thumbnails, Dropbox cache, and place index will all be deleted and rebuilt.")
                }
            }
        }
    }

    private func clearAll() async {
        isClearing = true
        defer { isClearing = false }
        await ThumbnailCache.shared.clear()
        if let dropboxStore { await dropboxStore.clearCache() }
        if let placeScanner { await placeScanner.clearCache() }
    }
}
