import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import MobileCLIPKit
import MosaicSupport
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// Developer Options：以前は各設定タブに散在していた Debug をすべて1画面に集約する。
/// 先頭の Developer Mode トグル（既定 OFF）が ON のときだけ詳細診断・破壊的アクションを表示する。
/// 各パッケージの Debug は public セクション View（`DropboxDebugSection` 等）を合成して再利用する。
struct DeveloperSettingsView: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    let backupEngine: BackupEngine
    let placeScanner: PlaceScanner?
    let autoAlbumEngine: AutoAlbumEngine?

    @AppStorage(AppSettingsKeys.verboseLogging) private var verboseLogging = true

    @State private var enrichmentCount = 0
    @State private var cachedPlaceCount = 0
    @State private var isWorking = false

    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"

    var body: some View {
        Form {
            appInfoSection
            diagnosticsSection
            LocalPhotoDebugSection()
            DropboxDebugSection(dropboxAuth: dropboxAuth, store: store)
            BackupDebugSection(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
            placesDebugSection
            albumsDebugSection
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enrichmentCount = await autoAlbumEngine?.enrichmentCount() ?? 0
            cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
        }
    }

    // MARK: - App info

    private var appInfoSection: some View {
        Section("App") {
            LabeledContent("Build", value: build)
            LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "-")
            LabeledContent("Minimum iOS", value: "17.0")
            LabeledContent("Device", value: UIDevice.current.model)
            Toggle("Verbose logging", isOn: $verboseLogging)
        }
    }

    // MARK: - Diagnostics（端末上のログ・メモリ）

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Memory footprint",
                           value: currentMemoryFootprintMB().map { String(format: "%.0f MB", $0) } ?? "—")
            LabeledContent("CLIP model", value: MobileCLIP.modelsBundled ? "Bundled" : "Not bundled")
            NavigationLink("Diagnostics log") { DiagnosticsLogView() }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("On-device log of errors, uncaught exceptions and memory pressure. Useful when the app misbehaves without a Mac/Console.")
        }
    }

    // MARK: - Places debug

    private var placesDebugSection: some View {
        Section("Places — Debug") {
            LabeledContent("Geocoded places cached", value: "\(cachedPlaceCount)")
            Button {
                Task { await rescanPlaces() }
            } label: {
                workingLabel("Rescan now")
            }
            .disabled(isWorking || placeScanner == nil)
            Button(role: .destructive) {
                Task { await clearAndRescanPlaces() }
            } label: {
                workingLabel("Clear place + geocode caches")
            }
            .disabled(isWorking || placeScanner == nil)
        }
    }

    // MARK: - Albums debug

    private var albumsDebugSection: some View {
        Section("Albums — Debug") {
            LabeledContent("Enriched photos", value: "\(enrichmentCount)")
            Button("Clear Albums & Enrichment", role: .destructive) {
                Task {
                    await autoAlbumEngine?.clear()
                    enrichmentCount = await autoAlbumEngine?.enrichmentCount() ?? 0
                }
            }
            .disabled(autoAlbumEngine == nil)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func workingLabel(_ title: String) -> some View {
        if isWorking {
            HStack { ProgressView().controlSize(.small); Text("Working…") }
        } else {
            Text(title)
        }
    }

    private func rescanPlaces() async {
        guard let placeScanner else { return }
        isWorking = true
        defer { isWorking = false }
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }

    private func clearAndRescanPlaces() async {
        guard let placeScanner else { return }
        isWorking = true
        defer { isWorking = false }
        await placeScanner.clearCache()
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }
}
