import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 「Places」タブ：場所アルバムの統計・グリッド粒度/再スキャン間隔の設定・Debug アクション。
struct PlacesSettingsView: View {
    let scanner: PlaceScanner?

    @AppStorage(PlacesSettingsKeys.gridStepDegrees)      private var gridStep = 0.02
    @AppStorage(PlacesSettingsKeys.rescanIntervalSeconds) private var rescanInterval = 10

    @State private var cachedPlaceCount = 0
    @State private var isWorking = false

    var body: some View {
        Group {
            Section("Places") {
                LabeledContent("Place albums", value: "\(scanner?.places.count ?? 0)")
                LabeledContent("Located photos", value: "\(scanner?.photoCount ?? 0)")
            }

            Section("Grouping") {
                Picker("Grid granularity", selection: $gridStep) {
                    Text("Fine (~1 km)").tag(0.01)
                    Text("Default (~2 km)").tag(0.02)
                    Text("Coarse (~5 km)").tag(0.05)
                    Text("Very coarse (~10 km)").tag(0.1)
                }
                Picker("Rescan interval", selection: $rescanInterval) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                }
                Text("Granularity changes take effect on the next rescan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Debug") {
                LabeledContent("Geocoded places cached", value: "\(cachedPlaceCount)")

                Button {
                    Task { await rescanNow() }
                } label: {
                    workingLabel("Rescan now")
                }
                .disabled(isWorking || scanner == nil)

                Button(role: .destructive) {
                    Task { await clearAndRescan() }
                } label: {
                    workingLabel("Clear place + geocode caches")
                }
                .disabled(isWorking || scanner == nil)
            }
        }
        .task { cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount }
    }

    @ViewBuilder
    private func workingLabel(_ title: String) -> some View {
        if isWorking {
            HStack { ProgressView().controlSize(.small); Text("Working…") }
        } else {
            Text(title)
        }
    }

    private func rescanNow() async {
        guard let scanner else { return }
        isWorking = true
        defer { isWorking = false }
        await scanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }

    private func clearAndRescan() async {
        guard let scanner else { return }
        isWorking = true
        defer { isWorking = false }
        await scanner.clearCache()
        await scanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }
}
