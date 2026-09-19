import AutoAlbumCore
import DropboxKit
import MobileCLIPKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// 「AI 解析の状況」（ユーザー向け・設定 → Albums & Search）。
/// AI アルバム／意味検索／ピープルの索引付けが「どこまで進んでいるか・今動いているか・
/// 最後にいつ進んだか」を可視化する。デバッグ用の詳細（Developer Options）とは別に、
/// 「動いているのか分からない」を解消するための画面。
///
/// - 進捗数は `.task`／処理状態の変化で非同期取得し `@State` に反映（AutoAlbumSettingsView と同型）。
/// - 「解析中」は `BackgroundActivityMonitor.shared` と各エンジンのライブフラグを body で直読み
///   （@Observable なので自動追従）。
/// - 「最後に解析した時間」は `AnalysisActivity`（各パスのバッチ確定時に記録）から読む。
struct AIAnalysisStatusView: View {
    let engine: AutoAlbumEngine
    let people: PeopleEngine
    let mergedStore: MergedPhotoStore
    let dropboxStore: DropboxPhotoStore
    /// 解析セッション（「今すぐ解析」・ADR-182）。
    let session: AnalysisSession

    /// 数字と数え直しループの持ち主（ADR-196）。**`.task` が Section ごとに配られても 1 本**。
    @State private var model = AnalysisStatusModel()
    /// 「今すぐ解析」がアプリを離れても続くか（ADR-197）。
    /// ⚠️ `UserDefaults` の直読みではなく `@AppStorage`——直読みだと選んでも表示が前の値のままで
    /// 壊れて見える（ADR-193 のときのレビュー指摘）。
    @AppStorage(AppSettingsKeys.analysisContinueAfterLeaving) private var continueAfterLeaving = true

    private var deps: AnalysisStatusModel.Deps {
        .init(engine: engine, people: people, dropboxStore: dropboxStore, session: session)
    }

    private var monitor: BackgroundActivityMonitor { .shared }
    private var facesAvailable: Bool { people.isFaceModelAvailable }

    /// 全パスが解析中でないか（＝いま何かが動いているか）。
    private var isAnalyzing: Bool {
        engine.isTagging || monitor.isEmbedding || people.isScanning
    }

    var body: some View {
        Group {
            statusSection
            if model.staleEmbeddings > 0 || model.faceMigration != nil { modelUpdateSection }
            semanticSearchSection
            sceneTagsSection
            if facesAvailable { peopleSection }
            actionSection
            blockersSection
        }
        // ⚠️ この修飾子は **Section ごとに配られる**（body は `Group`）。`ensureRunning` は
        //    何度呼ばれても 1 本に畳むので素通しでよい。ループの持ち主はモデルなので、
        //    スクロールで Section が消えても死なない（ADR-196・旧実装の 3 つの旗を置換）。
        .task { model.ensureRunning(deps) }
    }

    // MARK: - 現在の状態

    private var statusSection: some View {
        Section {
            HStack {
                Label {
                    Text(isAnalyzing ? L("Analyzing…") : L("Idle"))
                } icon: {
                    Image(systemName: isAnalyzing ? "sparkles" : "checkmark.circle")
                        .foregroundStyle(isAnalyzing ? Color.accentColor : .secondary)
                }
                Spacer()
                if isAnalyzing { ProgressView().controlSize(.small) }
            }
            if isAnalyzing {
                if monitor.isEmbedding {
                    LabeledContent(L("Indexing for search"), value: remainingText(monitor.embedRemaining))
                }
                if people.isScanning {
                    LabeledContent(L("Scanning faces"), value: remainingText(people.remaining))
                }
            }
        } header: {
            Text("Status")
        } footer: {
            Text(isAnalyzing
                 ? L("The app is analyzing your photos in the background right now.")
                 : L("Analysis is not running right now. It resumes automatically under the conditions you set in Processing Timing, or tap “Analyze Now” below."))
        }
    }

    // MARK: - 意味検索（CLIP 埋め込み）

    private var semanticSearchSection: some View {
        Section {
            progressRow(done: model.progress.embedded, total: model.progress.total,
                        running: monitor.isEmbedding)
            lastRunRow(.embeddings)
        } header: {
            Text("Semantic Search")
        } footer: {
            Text("Each photo (device and Dropbox) gets a compact “fingerprint” so you can search by natural language and build AI albums. This is the main index.")
        }
    }

    // MARK: - シーンタグ

    private var sceneTagsSection: some View {
        Section {
            progressRow(done: model.progress.sceneTagged, total: model.progress.total,
                        running: engine.isTagging)
            lastRunRow(.sceneTags)
        } header: {
            Text("Scene Tags")
        } footer: {
            Text("Recognized subjects (e.g. beach, food, dog) shown on each photo and used to rank search results.")
        }
    }

    // MARK: - ピープル（顔）

    private var peopleSection: some View {
        Section {
            progressRow(done: model.faceScanned, total: model.faceCandidates, running: people.isScanning)
            LabeledContent(L("People found"), value: "\(people.people.count)")
            LabeledContent(L("Faces detected"), value: "\(model.facesDetected)")
            lastRunRow(.faces)
        } header: {
            Text("People")
        } footer: {
            Text("Faces are detected and grouped into people entirely on device, for both device and Dropbox photos (cloud faces use already-cached thumbnails, so no extra downloads).")
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            if session.isActive {
                sessionProgressRow
                Button(role: .destructive) {
                    session.stop(.user)
                } label: {
                    Label(L("Stop"), systemImage: "stop.circle")
                }
            } else {
                Button {
                    session.start()
                } label: {
                    Label(L("Analyze Now"), systemImage: "play.circle")
                }
                if case .stopped(let reason) = session.state, let text = stopText(reason) {
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { continueAfterLeaving },
                                 set: { continueAfterLeaving = $0 })) {
                Label(L("Keep Analyzing After Leaving the App"),
                      systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            Toggle(isOn: Binding(get: { session.keepScreenOn }, set: { session.keepScreenOn = $0 })) {
                Label(L("Keep Screen On While Analyzing"), systemImage: "sun.max")
            }
            NavigationLink {
                Form { AutoAlbumSettingsView(engine: engine) }
                    .navigationTitle(L("Album Automation"))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(L("Processing Timing & Speed"), systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("Analysis runs by itself whenever the conditions in Processing Timing are met — while your iPhone is locked, and also while the app is open once you have not touched the screen for 20 seconds. Nothing to resume: it simply continues from where it is.")
            + Text(verbatim: "\n\n")
            + Text("“Analyze Now” runs faces, tags, and the search index at full speed, ignoring the conditions above (except heat and a low battery). With “Keep Analyzing After Leaving the App” on, it continues after you leave — progress appears in the Dynamic Island / Lock Screen, where you can also stop it. Turn it off if you would rather not see that indicator; analysis then runs only while the app is open. Either way, nightly background analysis is unaffected.")
            + Text(verbatim: "\n\n")
            + Text("Locking the screen may pause it (a known iOS issue Apple is fixing). Keep Screen On avoids that — charging is recommended. The device may get warm; analysis pauses on its own if it gets too hot. Otherwise analysis runs automatically based on Processing Timing.")
        }
    }

    // MARK: - 自動で進まない理由（diagnostics-81）

    /// いま自動の解析を止めている条件。**ゲートそのものを読む**（ADR-196）。
    ///
    /// ⚠️ ここで条件を再実装しない。以前は `AnalysisBlockerDiagnosis` が同じ質問に別々のコードで
    /// 答えており、ゲートが閉じているのに「すべての条件を満たしています」と言える状態だった。
    /// 「解析が動くか」（クラウド分＝回線も要る）と「処理枠が来るか」の両方を見る。
    private var currentBlockers: [BackgroundYield.Blocker] {
        let analysis = BackgroundYield.verdict(for: .cloudTrickle).blockers
        let window = BackgroundYield.verdict(for: .window).blockers
        return analysis + window.filter { !analysis.contains($0) }
    }

    /// 「条件は満たしているのに、半日以上 処理枠が来ていない」か。
    private var isWindowStarved: Bool {
        AnalysisWindowHealth.isStarved(
            blockers: currentBlockers,
            minutesSinceLastWindow: HeavyWorkScheduler.minutesSinceLastWindow())
    }

    /// 自動の解析が止まっている理由を並べる。全部満たしていれば、その旨と最後の処理枠を出す。
    @ViewBuilder
    private var blockersSection: some View {
        let blockers = currentBlockers
        Section {
            if blockers.isEmpty {
                Label(L("All conditions for automatic analysis are met."), systemImage: "checkmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let minutes = HeavyWorkScheduler.minutesSinceLastWindow() {
                    LabeledContent(L("Last background window"), value: elapsedText(minutes))
                }
                if isWindowStarved {
                    Text("iOS has not given the app a background window for a long time. This can happen if the app was swiped away from the app switcher, or if iOS ended it to free memory. Tap Analyze Now (keep the device plugged in) to continue right away.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ForEach(blockers, id: \.self) { blocker in
                    Label(blockerText(blocker), systemImage: blockerIcon(blocker))
                        .font(.subheadline)
                }
                Text("Analysis resumes by itself once these are resolved. “Analyze Now” ignores all of them except heat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Automatic Analysis")
        }
    }

    private func blockerText(_ blocker: BackgroundYield.Blocker) -> String {
        switch blocker {
        case .automaticOff:         return L("Automatic analysis is turned off (Processing Timing).")
        case .foregroundAnalysisOff: return L("“Analyze while the app is open” is off, so analysis waits until you leave the app or lock your iPhone.")
        case .backgroundRefreshOff: return L("Background App Refresh is off for this app — iOS never gives it a background window. Turn it on in Settings → General → Background App Refresh.")
        case .lowPowerMode:         return L("Low Power Mode is on.")
        case .notCharging:          return L("Not charging (the current setting runs heavy work only while charging).")
        case .powerOff:             return L("Background work is turned off in Background & Battery.")
        case .lowBattery:           return L("The battery is below 20% and the device is not charging.")
        case .networkBlocked:       return L("The current network does not meet the setting, so cloud photos are skipped.")
        case .tooHot:               return L("Paused because the device is warm — charging is prioritized.")
        case .memoryPressure:       return L("Paused briefly because memory is tight.")
        case .heavyLoad:            return L("Paused briefly while the photo library finishes loading.")
        case .generating:           return L("Paused briefly while albums are being built.")
        case .uiBusy:               return L("Paused because you are viewing photos right now.")
        case .foregroundNotIdle:    return L("Paused because you are using the app — it resumes 20 seconds after you stop touching the screen.")
        case .appActive, .boostRunning: return L("Album building waits until you leave the app.")
        }
    }

    private func blockerIcon(_ blocker: BackgroundYield.Blocker) -> String {
        switch blocker {
        case .automaticOff:              return "pause.circle"
        case .foregroundAnalysisOff:     return "hand.raised"
        case .backgroundRefreshOff:      return "app.badge.checkmark"
        case .lowPowerMode, .lowBattery: return "battery.25"
        case .notCharging, .powerOff:    return "powerplug"
        case .tooHot:                    return "thermometer.medium"
        case .networkBlocked:            return "wifi.slash"
        case .memoryPressure, .heavyLoad: return "memorychip"
        case .generating:                return "rectangle.stack"
        case .uiBusy, .foregroundNotIdle, .appActive, .boostRunning: return "hand.tap"
        }
    }

    private func elapsedText(_ minutes: Int) -> String {
        minutes < 60 ? L("\(minutes) min ago") : L("\(minutes / 60) h ago")
    }

    /// セッション中の進捗行（残り枚数・モード）。
    private var sessionProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("Analyzing now"), systemImage: "sparkles")
                    .font(.subheadline).foregroundStyle(Color.accentColor)
                Spacer()
                Text(remainingText(session.remaining)).font(.subheadline).foregroundStyle(.secondary)
            }
            if session.peakRemaining > 0 {
                ProgressView(value: Double(max(0, session.peakRemaining - session.remaining)),
                             total: Double(session.peakRemaining))
            }
            Text(session.mode == .continued
                 ? L("Continues after you leave the app.")
                 : L("Runs while the app is open."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stopText(_ reason: AnalysisSession.StopReason) -> String? {
        switch reason {
        case .finished: return L("Everything is analyzed.")
        case .expired: return L("iOS ended the boost. Analysis keeps going automatically while charging — or tap Analyze Now.")
        case .lowBattery: return L("Stopped because the battery is low. Plug in and tap Analyze Now to continue.")
        case .blocked(let blockers):
            // 「すべて解析済みです」と嘘をつかない。止めている理由をそのまま出す。
            guard let first = blockers.first else { return L("Everything is analyzed.") }
            return blockerText(first)
        case .user, .leftApp: return nil
        }
    }

    // MARK: - 部品

    /// 進捗バー＋「N / M 枚（P%）」。処理中はバッジも出す。
    @ViewBuilder
    private func progressRow(done: Int, total: Int, running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("\(done) of \(total) photos"))
                    .font(.subheadline)
                Spacer()
                if total > 0 {
                    Text(percentText(done: done, total: total))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(done >= total ? Color.green : .secondary)
                }
            }
            ProgressView(value: Double(min(done, max(total, 0))),
                         total: Double(max(total, 1)))
                .tint(done >= total && total > 0 ? .green : .accentColor)
            if running {
                Label(L("Analyzing now"), systemImage: "sparkles")
                    .font(.caption).foregroundStyle(Color.accentColor)
            } else if total > 0 && done >= total {
                Label(L("Complete"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private func lastRunRow(_ pass: AnalysisActivity.Pass) -> some View {
        LabeledContent(L("Last analyzed"), value: lastRunText(pass))
    }

    // MARK: - モデル更新（ADR-186）

    /// モデルが更新された後、索引を**少しずつ**新モデルへ移している間だけ出す。
    /// DB を丸ごと作り直さないので、この間も検索・ピープルは従来の結果で使える。
    private var modelUpdateSection: some View {
        Section {
            if model.staleEmbeddings > 0 {
                LabeledContent(L("Search index"), value: L("\(model.staleEmbeddings) left"))
            }
            if let m = model.faceMigration {
                progressRow(done: m.scanned, total: m.total, running: people.isScanning)
            }
        } header: {
            Text("Model Update")
        } footer: {
            Text("A newer recognition model is included in this version. Photos are re-analyzed gradually, newest first, while search and People keep working with the previous results. People switches to the new model once most photos are done; names are carried over.")
        }
    }

    private func percentText(done: Int, total: Int) -> String {
        guard total > 0 else { return "—" }
        let pct = Int((Double(min(done, total)) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    private func remainingText(_ n: Int) -> String {
        n > 0 ? L("\(n) left") : L("finishing…")
    }

    private func lastRunText(_ pass: AnalysisActivity.Pass) -> String {
        guard let date = AnalysisActivity.lastActivity(pass) else { return L("Not yet") }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .full
        return fmt.localizedString(for: date, relativeTo: Date())
    }
}
