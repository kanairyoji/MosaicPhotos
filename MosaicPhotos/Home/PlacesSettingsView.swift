import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

/// 「Places」：場所アルバムの統計・グリッド粒度/再スキャン間隔。
/// 診断・キャッシュ消去（geocode キャッシュ・rescan）は Developer Options へ移設した。
struct PlacesSettingsView: View {
    let scanner: PlaceScanner?

    @AppStorage(PlacesSettingsKeys.gridStepDegrees)      private var gridStep = 0.02
    @AppStorage(PlacesSettingsKeys.rescanIntervalSeconds) private var rescanInterval = PlacesSettingsKeys.defaultRescanIntervalSeconds

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
        }
    }
}
