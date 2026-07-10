import AutoAlbumCore
import MosaicSupport
import SwiftUI

/// 「Albums」タブ：時間＋場所の自動アルバム生成の制御・パラメータ・Debug。
struct AutoAlbumSettingsView: View {
    let engine: AutoAlbumEngine?

    @AppStorage(AutoAlbumSettingsKeys.backgroundEnabled)        private var backgroundEnabled = false
    @AppStorage(AutoAlbumSettingsKeys.excludeAlbumed)           private var excludeAlbumed = false
    @AppStorage(AutoAlbumSettingsKeys.includeCloud)             private var includeCloud = true
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled)        private var pathAlbumsEnabled = false
    // 旅行抽出パラメータ
    @AppStorage(AutoAlbumSettingsKeys.frequentMinDistinctDays)  private var frequentMinDays = 5
    @AppStorage(AutoAlbumSettingsKeys.homeDistanceKm)           private var homeDistanceKm = 25
    @AppStorage(AutoAlbumSettingsKeys.minTripPhotos)            private var minTripPhotos = 3
    @AppStorage(AutoAlbumSettingsKeys.maxTripGapDays)           private var maxTripGapDays = 2
    @AppStorage(AutoAlbumSettingsKeys.gridStepMilliDegrees)     private var gridStepMilliDeg = 20

    @State private var taggedCount = 0
    @State private var untaggedCount = 0
    @AppStorage(AutoAlbumSettingsKeys.backgroundProcessingLevel)
    private var backgroundLevel = BackgroundProcessing.defaultIndex
    @AppStorage(HeavyWorkTiming.defaultsKey)
    private var heavyWorkTiming = HeavyWorkTiming.nightly.rawValue

    private var selectedPreset: BackgroundProcessingPreset {
        BackgroundProcessing.preset(at: backgroundLevel)
    }

    private var timingFooter: String {
        switch HeavyWorkTiming(rawValue: heavyWorkTiming) ?? .nightly {
        case .paused:
            return L("Nothing runs automatically. Use “Process Now” to index manually.")
        case .nightly:
            return L("Runs only while your iPhone is charging, on Wi-Fi, and not in use (locked or in another app) — typically overnight. Zero impact while you use the app.")
        case .chargeActive:
            return L("Additionally runs between your interactions while the app is open (charging + Wi-Fi). Stops the instant you touch the screen; slight warmth possible.")
        case .battery:
            return L("Additionally runs on battery (Wi-Fi, above 20% charge, Low Power Mode off). Uses battery.")
        case .unlimited:
            return L("Runs whenever possible, including on mobile data. Uses battery and may use significant cellular data.")
        }
    }

    var body: some View {
        Group {
            // AI 処理を「いつ動かすか」（5段階・既定=夜間のみ）。「どれくらい強く動かすか」
            // （下の Background speed）とは別軸。判定本体は HeavyWorkTiming.allows（テスト済み）。
            Section {
                Picker("When to process", selection: $heavyWorkTiming) {
                    Text(L("Paused — manual only")).tag(HeavyWorkTiming.paused.rawValue)
                    Text(L("Automatic — while not in use (recommended)")).tag(HeavyWorkTiming.nightly.rawValue)
                    Text(L("Also while using the app (charging)")).tag(HeavyWorkTiming.chargeActive.rawValue)
                    Text(L("Also on battery (Wi-Fi)")).tag(HeavyWorkTiming.battery.rawValue)
                    Text(L("No limits (mobile data too)")).tag(HeavyWorkTiming.unlimited.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Processing Timing")
            } footer: {
                Text(timingFooter)
            }

            Section {
                Picker("Background speed", selection: $backgroundLevel) {
                    ForEach(BackgroundProcessing.presets) { preset in
                        // 段階名＋その段のパラメータ（件数 / 休止秒）をそのまま提示する。
                        // 段階名（"Balanced" 等）は動的 String なので個別キーで翻訳を引く。
                        Text(L("\(presetName(preset)) — \(preset.batchSize)/batch · \(pause(preset))"))
                            .tag(preset.id)
                    }
                }
                LabeledContent("Batch size", value: L("\(selectedPreset.batchSize) photos"))
                LabeledContent("Pause between batches", value: pause(selectedPreset))
            } header: {
                Text("Background Processing")
            } footer: {
                Text(L("How hard the app works in the background to add CLIP embeddings (used for search). Lower is gentler on battery, network and scrolling but slower to finish; higher is faster but heavier. Takes effect on the next batch."))
            }

            Section("Image Recognition (AI tags)") {
                LabeledContent("Tagged photos", value: "\(taggedCount)")
                if untaggedCount > 0 {
                    LabeledContent("Pending", value: "\(untaggedCount)")
                }
                Button {
                    Task {
                        await engine?.reanalyzePhotos()
                        await refreshCounts()
                    }
                } label: {
                    BusyLabel("Re-analyze All Photos", busy: "Analyzing…",
                              isBusy: engine?.isTagging == true)
                }
                .disabled(engine == nil || engine?.isTagging == true)
                Text("Clears all recognition tags (objects, scenes, text, CLIP) and re-analyzes every local photo with the latest model. Metadata (date, place, people) is kept. Runs in the background and may take a while.")
                    .font(.caption).foregroundStyle(.secondary)
                // C1: 重い処理は「充電中＋待機時間」にだけ進む方針を明示し、手動で即開始もできるようにする。
                Button {
                    BackgroundYield.boostHeavyWork()
                    engine?.scheduleBackgroundFill()
                } label: {
                    Label(L("Process Now (while charging)"), systemImage: "bolt.badge.clock")
                }
                .disabled(engine == nil)
                Text("Indexing runs automatically while the device is charging and idle (or locked). “Process Now” starts immediately for 30 minutes — charging is still required.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Time & Place Albums") {
                LabeledContent("Albums", value: "\(engine?.albums.count ?? 0)")
                if let engine, !engine.status.isEmpty {
                    LabeledContent("Last run", value: engine.status)
                }
                Button {
                    Task { await engine?.generate() }
                } label: {
                    BusyLabel("Generate Now", busy: "Generating…",
                              isBusy: engine?.isGenerating == true)
                }
                .disabled(engine == nil || engine?.isGenerating == true)
                Toggle("Include Dropbox photos", isOn: $includeCloud)
                Toggle("Auto-generate in background", isOn: $backgroundEnabled)
            }

            Section("Trip Detection") {
                Stepper(value: $frequentMinDays, in: 2...30) {
                    LabeledContent("Regular place ≥ days", value: "\(frequentMinDays)")
                }
                Picker("Away-from-home distance", selection: $homeDistanceKm) {
                    Text("10 km").tag(10); Text("25 km").tag(25); Text("50 km").tag(50); Text("100 km").tag(100)
                }
                Stepper(value: $minTripPhotos, in: 1...30) {
                    LabeledContent("Min photos per trip", value: "\(minTripPhotos)")
                }
                Stepper(value: $maxTripGapDays, in: 0...14) {
                    LabeledContent("Merge gap (days)", value: "\(maxTripGapDays)")
                }
                Text("Consecutive days away from home are merged into one trip (a multi-day trip is not split per day). A larger merge gap tolerates more blank days within a trip; a stay at home starts a new trip.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Folder-name Albums") {
                NavigationLink {
                    PathAlbumSettingsView(engine: engine)
                } label: {
                    LabeledContent("From Dropbox folders", value: pathAlbumsEnabled ? "On" : "Off")
                }
                Text("Infer a separate set of albums from Dropbox folder names via regex rules. Shown in the “Albums” section on the home screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Advanced") {
                Picker("Location granularity", selection: $gridStepMilliDeg) {
                    Text("~1 km").tag(10); Text("~2 km").tag(20); Text("~5 km").tag(50); Text("~10 km").tag(100)
                }
                Toggle("Exclude photos already in an album", isOn: $excludeAlbumed)
                Text("Changes apply on the next generation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await refreshCounts() }
        .onChange(of: engine?.isTagging) { _, _ in Task { await refreshCounts() } }
    }

    /// 段階名の翻訳（"Balanced" →「バランス」等）。キーはプリセット定義の英語名そのまま。
    private func presetName(_ preset: BackgroundProcessingPreset) -> String {
        L(String.LocalizationValue(preset.name))
    }

    private func pause(_ preset: BackgroundProcessingPreset) -> String {
        preset.pauseSeconds < 1
            ? String(format: L("%.1fs pause"), preset.pauseSeconds)
            : L("\(Int(preset.pauseSeconds))s pause")
    }

    private func refreshCounts() async {
        let counts = await engine?.recognitionCounts()
        taggedCount = counts?.tagged ?? 0
        untaggedCount = counts?.untagged ?? 0
    }
}
