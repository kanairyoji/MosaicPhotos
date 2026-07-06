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
    /// ストア／エンジン一式（SettingsView と同じく一括で受け取り、引数漏れを防ぐ）。
    let stores: HomeStores

    private var dropboxAuth: DropboxAuthService { stores.dropboxStore.auth }
    private var store: DropboxPhotoStore { stores.dropboxStore }
    private var backupEngine: BackupEngine { stores.backupEngine }
    private var placeScanner: PlaceScanner { stores.placeScanner }
    private var autoAlbumEngine: AutoAlbumEngine { stores.autoAlbumEngine }
    private var peopleEngine: PeopleEngine { stores.peopleEngine }

    @AppStorage(AppSettingsKeys.verboseLogging) private var verboseLogging = true
    @AppStorage(AppSettingsKeys.perfTracing) private var perfTracing = false
    @AppStorage(AppSettingsKeys.faceScanOnSimulator) private var faceScanOnSimulator = false
    /// デバッグ: 重い処理のゲートを全面無効化（ランタイムのみ・再起動でリセット）。
    @State private var forceHeavyWork = BackgroundYield.debugForceHeavyWork
    @State private var heavyWorking = false
    /// BG タスク検証: 予約状態と「その場実行」中フラグ。
    @State private var bgPendingStatus = "…"
    @State private var bgDebugRunning = false

    @State private var enrichmentCount = 0
    @State private var cachedPlaceCount = 0
    @State private var isWorking = false

    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"

    var body: some View {
        Form {
            appInfoSection
            diagnosticsSection
            heavyWorkDebugSection
            backgroundTaskDebugSection
            MemoryDebugSection()
            LocalPhotoDebugSection()
            DropboxDebugSection(dropboxAuth: dropboxAuth, store: store)
            BackupDebugSection(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
            placesDebugSection
            albumsDebugSection
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enrichmentCount = await autoAlbumEngine.enrichmentCount()
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
            LabeledContent("Face model", value: FaceModel.modelBundled ? "Bundled" : "Not bundled")
            LabeledContent("VLM (captions)", value: VLM.modelsBundled ? "Bundled" : "Not bundled")
            NavigationLink("Diagnostics log") { DiagnosticsLogView() }
            Toggle("Performance tracing", isOn: $perfTracing)
                .onChange(of: perfTracing) { _, on in PerfTrace.isEnabled = on }
            #if targetEnvironment(simulator)
            Toggle("Face scan in Simulator (slow)", isOn: $faceScanOnSimulator)
            #endif
            Button("Reset people (rescan faces)", role: .destructive) {
                Task { await peopleEngine.reset() }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("On-device log of errors, uncaught exceptions and memory pressure. Useful when the app misbehaves without a Mac/Console. "
                 + "Performance tracing writes screen-transition latency (screen.*) and Dropbox timing (network/cache/decode) to the diagnostics log and os_signpost; turn on, reproduce, then off.")
        }
    }

    // MARK: - Heavy work debug（バックグラウンド専用処理の強制実行）

    /// 通常は「電源＋アイドル（またはロック中）」でしか動かない重い処理を、その場で動かして検証する。
    private var heavyWorkDebugSection: some View {
        Section {
            Toggle("Force heavy work gates open", isOn: $forceHeavyWork)
                .onChange(of: forceHeavyWork) { _, on in BackgroundYield.debugForceHeavyWork = on }
            LabeledContent("Heavy work allowed", value: BackgroundYield.heavyWorkAllowed ? "Yes" : "No")
            Button {
                Task {
                    heavyWorking = true
                    await autoAlbumEngine.generate()
                    heavyWorking = false
                }
            } label: {
                workingRow("Generate albums now", spinning: heavyWorking)
            }
            .disabled(heavyWorking)
            Button {
                Task {
                    heavyWorking = true
                    await autoAlbumEngine.debugRefreshAIAlbumsFull()
                    heavyWorking = false
                }
            } label: {
                workingRow("AI albums: full re-evaluate now", spinning: heavyWorking)
            }
            .disabled(heavyWorking)
            Button("Start CLIP embedding now") {
                autoAlbumEngine.scheduleBackgroundFill()
            }
        } header: {
            Text("Heavy Work — Debug")
        } footer: {
            Text("These normally run only while charging and idle (or via the lock-screen background task). "
                 + "The toggle disables the power/idle/UI gates until the app restarts. "
                 + "Embedding still skips on the simulator (CLIP is CPU-only there).")
        }
    }

    // MARK: - Background task debug（夜間処理の検証・デバッガ不要）

    /// ロック中実行（BGProcessingTask）の検証用。実際の「OS がロック中に起こす」瞬間は
    /// OS 裁量のため、(1) 予約されているか、(2) 最後にいつ実行されたか、(3) 同じルーチンを
    /// その場で実行して中身を確認、の 3 点で検証できるようにする。
    private var backgroundTaskDebugSection: some View {
        Section {
            LabeledContent("Scheduled", value: bgPendingStatus)
            LabeledContent("Last BG run",
                           value: UserDefaults.standard.string(forKey: AppSettingsKeys.bgTaskLastRun) ?? "never")
            Button("Submit BG request now") {
                HeavyWorkScheduler.submit()
                Task { bgPendingStatus = await HeavyWorkScheduler.pendingStatus() }
            }
            Button {
                bgDebugRunning = true
                HeavyWorkScheduler.debugRunNow()
                // 完了検知は簡易ポーリング（表示用）。ルーチン自体は独立して走る。
                Task {
                    while HeavyWorkScheduler.isDebugRunning {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    bgDebugRunning = false
                }
            } label: {
                if bgDebugRunning {
                    HStack { ProgressView().controlSize(.small); Text("Running BG routine… (max 3 min)") }
                } else {
                    Text("Run BG routine now (foreground test)")
                }
            }
            .disabled(bgDebugRunning)
        } header: {
            Text("Background Task — Debug")
        } footer: {
            Text("Verifies the lock-screen task without a debugger: “Run BG routine now” executes the exact same "
                 + "routine in the foreground (gates temporarily forced open, 3-minute cap, result recorded in "
                 + "Last BG run as “manual-…”). The real lock-screen launch is at the OS's discretion — "
                 + "verify overnight (charging + locked) via Last BG run. Note: on the simulator, scheduling "
                 + "is unsupported and CLIP embedding is skipped.")
        }
        .task { bgPendingStatus = await HeavyWorkScheduler.pendingStatus() }
    }

    @ViewBuilder
    private func workingRow(_ title: String, spinning: Bool) -> some View {
        if spinning {
            HStack { ProgressView().controlSize(.small); Text(title) }
        } else {
            Text(title)
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
            .disabled(isWorking)
            Button(role: .destructive) {
                Task { await clearAndRescanPlaces() }
            } label: {
                workingLabel("Clear place + geocode caches")
            }
            .disabled(isWorking)
        }
    }

    // MARK: - Albums debug

    private var albumsDebugSection: some View {
        Section("Albums — Debug") {
            LabeledContent("Enriched photos", value: "\(enrichmentCount)")
            Button("Clear Albums & Enrichment", role: .destructive) {
                Task {
                    await autoAlbumEngine.clear()
                    enrichmentCount = await autoAlbumEngine.enrichmentCount()
                }
            }
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
        isWorking = true
        defer { isWorking = false }
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }

    private func clearAndRescanPlaces() async {
        isWorking = true
        defer { isWorking = false }
        await placeScanner.clearCache()
        await placeScanner.rescan()
        cachedPlaceCount = await PlaceNameResolver.shared.cachedPlaceCount
    }
}
