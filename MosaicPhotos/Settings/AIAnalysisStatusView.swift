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

    /// ⚠️ `UserDefaults` の直読みでは**画面が更新されない**（レビュー指摘）。選んでも表示が
    /// 前の値のまま＝壊れて見える。`@AppStorage` にして SwiftUI に変更を伝える。
    @AppStorage(AppSettingsKeys.analysisContinuation) private var continuationRaw = AnalysisContinuation.default.rawValue
    @AppStorage(AppSettingsKeys.analysisSessionPending) private var sessionPending = false

    /// 数え直しを重ねないための札（Section ごとに配られる `.task` の仕事を畳む）。
    @State private var refreshInFlight = false
    /// 実行中に来た要求。**捨てずに拾い直す**（捨てると完了直後の更新が消える）。
    @State private var refreshRequested = false
    /// 拾い直しの中に「候補を数え直してほしい」要求（`reuseCandidatesWithin: 0`）が混じっていたか。
    @State private var refreshRequestedFresh = false

    @State private var progress = AnalysisProgress(total: 0, embedded: 0, sceneTagged: 0)
    /// 顔スキャン: 候補（スクリーンショット除外・端末＋クラウド）のうち済んだ枚数と候補総数。
    /// ⚠️ 記録の総数÷ライブラリ総数では、削除済みの記録と候補外の写真で「存在しない残り」が出る。
    @State private var faceScanned = 0
    @State private var faceCandidates = 0
    @State private var facesDetected = 0

    private var monitor: BackgroundActivityMonitor { .shared }
    private var facesAvailable: Bool { people.isFaceModelAvailable }

    /// 全パスが解析中でないか（＝いま何かが動いているか）。
    private var isAnalyzing: Bool {
        engine.isTagging || monitor.isEmbedding || people.isScanning
    }

    var body: some View {
        Group {
            statusSection
            if staleEmbeddings > 0 || faceMigration != nil { modelUpdateSection }
            semanticSearchSection
            sceneTagsSection
            if facesAvailable { peopleSection }
            actionSection
            blockersSection
        }
        // ⚠️ これらの修飾子も **Section ごとに配られる**（body は `Group`・レビュー指摘）。
        //    素通しだと開いた瞬間に refresh が約 7 本同時に走り、そのたびに 8.5 万件の候補列挙と
        //    FaceStore（@ModelActor）への問い合わせが重なって、人物一覧まで巻き添えで遅くなる
        //    （ADR-119 の「規模に比例する呼び出し」がそのまま 7 倍になる）。
        //    ビューの実体は 1 つなので、@State の札で 1 本に畳む。
        .task { await refreshOnce() }
        // 解析中は数秒おきに数え直す（実フィードバック: 「今すぐ解析」で進んでいるのに数字が動かない）。
        // 候補の列挙（8.5 万件）は 1 分に 1 回で足りるので、数え直しはカウントだけにする。
        // ⚠️ 「1 本だけ回す」札は使わない（レビュー指摘）。札を持つ Section が
        //    スクロールで消えるとループごと死に、**見えている間だけ数字が凍る**。
        //    7 本走らせたまま、下の `refreshOnce` で**仕事の方を畳む**。
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, isAnalyzing || session.isActive else { continue }
                await refreshOnce(reuseCandidatesWithin: 60)
            }
        }
        .onChange(of: engine.isTagging) { _, _ in Task { await refreshOnce() } }
        .onChange(of: people.isScanning) { _, _ in Task { await refreshOnce() } }
        // ⚠️ 画面の出入りの報告は**ここに書かない**（レビュー指摘）。この body は `Section` の
        // `Group` で、修飾子は各 Section へ配られる。`Form` は行を遅延生成するので、
        // スクロールしてセクションが画面外に出ただけで `onDisappear`＝解析が止まっていた。
        // 報告は Form 全体に付ける（`analysisScreenLifecycle`・呼び出し側の `SettingsView`）。
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
            progressRow(done: progress.embedded, total: progress.total,
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
            progressRow(done: progress.sceneTagged, total: progress.total,
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
            progressRow(done: faceScanned, total: faceCandidates, running: people.isScanning)
            LabeledContent(L("People found"), value: "\(people.people.count)")
            LabeledContent(L("Faces detected"), value: "\(facesDetected)")
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
                } else if sessionPending {
                    // 前回のセッションが終わっていない（ロック・OS の停止・アプリの終了）。
                    // 次にアプリを開いたときに自動再開するが、ここでも状況を伝える。
                    Label(L("The last analysis was interrupted. It resumes automatically when you open the app — or tap Analyze Now."),
                          systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { session.keepScreenOn }, set: { session.keepScreenOn = $0 })) {
                Label(L("Keep Screen On While Analyzing"), systemImage: "sun.max")
            }
            continuationPicker
            NavigationLink {
                Form { AutoAlbumSettingsView(engine: engine) }
                    .navigationTitle(L("Album Automation"))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(L("Processing Timing & Speed"), systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("“When You Leave the App” only decides whether analysis keeps running once you leave — nightly background analysis is unaffected by it.")
            + Text(verbatim: "\n\n")
            + Text("“Analyze Now” runs faces, tags, and the search index at full speed and keeps going after you leave the app — progress appears in the Dynamic Island / Lock Screen, where you can also stop it. It ends by itself when everything is analyzed, or if the battery drops below 20% while not charging.")
            + Text(verbatim: "\n\n")
            + Text("Locking the screen may pause it (a known iOS issue Apple is fixing). Keep Screen On avoids that — charging is recommended. The device may get warm; analysis pauses on its own if it gets too hot. Otherwise analysis runs automatically based on Processing Timing.")
        }
    }

    /// 「アプリを離れたときの解析」（ADR-193）。選んでいるのは表示ではなく**継続タスクを使う場面**
    /// ——進捗 UI は OS が出すもので、アプリからは消せないため。
    private var continuationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: Binding(
                get: { AnalysisContinuation(rawValue: continuationRaw) ?? .default },
                set: { continuationRaw = $0.rawValue })
            ) {
                Text("Keep going").tag(AnalysisContinuation.always)
                Text("Only when I start it").tag(AnalysisContinuation.manualOnly)
                Text("Only while this screen is open").tag(AnalysisContinuation.whileOpen)
            } label: {
                Label(L("When You Leave the App"), systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
            }
            Text(continuationHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var continuationHint: String {
        switch AnalysisContinuation(rawValue: continuationRaw) ?? .default {
        case .always:
            return L("Analysis continues after you leave the app, and resumes by itself when you open the app while charging. iOS shows a progress indicator on the Lock Screen and in the Dynamic Island while it runs — that indicator cannot be hidden.")
        case .manualOnly:
            return L("Only an analysis you start with Analyze Now keeps going after you leave the app. An interrupted analysis resumes while this screen is open and the device is charging.")
        case .whileOpen:
            return L("Analysis runs only while this screen is open, so no indicator appears. Nightly background analysis is unaffected.")
        }
    }

    // MARK: - 自動で進まない理由（diagnostics-81）

    /// いま自動の解析を止めている条件（アプリが知り得るものは全部出す）。
    private var currentBlockers: [AnalysisBlockerDiagnosis.Blocker] {
        AnalysisBlockerDiagnosis.blockers(
            automaticEnabled: HeavyWorkTiming.current != .paused,
            backgroundRefreshAvailable: UIApplication.shared.backgroundRefreshStatus == .available,
            lowPowerMode: PowerStateMonitor.shared.isLowPowerMode,
            requiresPower: BackgroundPowerPolicy(
                rawValue: UserDefaults.standard.integer(forKey: PowerStateMonitor.policyKey)) == .whileCharging,
            onPower: PowerStateMonitor.shared.isOnPower,
            thermalPaused: ThermalGate.shared.shouldPause(),
            networkAllowed: NetworkStateMonitor.shared.networkAllowed())
    }

    /// 「条件は満たしているのに、半日以上 処理枠が来ていない」か。
    private var isWindowStarved: Bool {
        AnalysisBlockerDiagnosis.isWindowStarved(
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

    private func blockerText(_ blocker: AnalysisBlockerDiagnosis.Blocker) -> String {
        switch blocker {
        case .automaticOff:        return L("Automatic analysis is turned off (Processing Timing).")
        case .backgroundRefreshOff: return L("Background App Refresh is off for this app — iOS never gives it a background window. Turn it on in Settings → General → Background App Refresh.")
        case .lowPowerMode:        return L("Low Power Mode is on.")
        case .notCharging:         return L("Not charging (the current setting runs heavy work only while charging).")
        case .tooHot:              return L("Paused because the device is warm — charging is prioritized.")
        case .networkBlocked:      return L("The current network does not meet the setting, so cloud photos are skipped.")
        }
    }

    private func blockerIcon(_ blocker: AnalysisBlockerDiagnosis.Blocker) -> String {
        switch blocker {
        case .automaticOff:         return "pause.circle"
        case .backgroundRefreshOff: return "app.badge.checkmark"
        case .lowPowerMode:         return "battery.25"
        case .notCharging:          return "powerplug"
        case .tooHot:               return "thermometer.medium"
        case .networkBlocked:       return "wifi.slash"
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
                 : L("Runs only while this screen is open."))
                .font(.caption).foregroundStyle(.secondary)
            if session.didAutoResume {
                Text("Resumed the analysis that was interrupted earlier.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stopText(_ reason: AnalysisSession.StopReason) -> String? {
        switch reason {
        case .finished: return L("Everything is analyzed.")
        case .expired: return L("iOS stopped the analysis. Tap Analyze Now to continue from where it left off.")
        case .lowBattery: return L("Stopped because the battery is low. Plug in and tap Analyze Now to continue.")
        case .deferred:
            return L("Some photos (cloud photos waiting for Wi‑Fi) are left for the next run. They continue automatically.")
        case .user, .leftScreen: return nil
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

    // MARK: - 取得・整形

    /// - Parameter reuseCandidatesWithin: この秒数以内に列挙した候補があれば使い回す（定期の数え直し用）。
    /// `refresh` を**同時に 1 本だけ**にする包み（重い列挙を 7 本走らせない）。
    ///
    /// ⚠️ 実行中に来た要求は**捨てずに畳む**（レビュー指摘）。捨てると、初回の列挙（数秒）の
    /// 最中に解析が終わったときの `.onChange` が消え、ポーリングも
    /// 「解析中でなければ数え直さない」ので、**終わった瞬間の数字が止まったまま**になる。
    private func refreshOnce(reuseCandidatesWithin seconds: TimeInterval = 0) async {
        if refreshInFlight {
            refreshRequested = true
            if seconds == 0 { refreshRequestedFresh = true }   // 明示の「新鮮に」を握り潰さない
            return
        }
        refreshInFlight = true
        defer { refreshInFlight = false }
        await refresh(reuseCandidatesWithin: seconds)
        // 実行中に来た要求は**最後まで拾う**（上限で切ると、切った先の要求が捨てられて
        // 完了直後の数字が凍る・レビュー指摘）。暴走しないのは、拾い直しでは候補の列挙を
        // 使い回す＝1 回が軽いため（4 秒ポーリングに追い越されて終わらなくなることが無い）。
        // ただし明示的に「新鮮に」と言われた要求（onChange）はその通り数え直す。
        while refreshRequested, !Task.isCancelled {
            refreshRequested = false
            let fresh = refreshRequestedFresh
            refreshRequestedFresh = false
            await refresh(reuseCandidatesWithin: fresh ? 0 : 60)
        }
    }

    private func refresh(reuseCandidatesWithin: TimeInterval = 0) async {
        async let prog = engine.analysisProgress()
        async let stats = people.scanStats()
        progress = await prog
        facesDetected = await stats.faces
        // 顔スキャンの分母は**候補そのもの**（スキャナと同じ列挙）、分子は「候補のうち済んだ数」。
        if facesAvailable {
            let candidates: [String]
            if let cached = cachedCandidates, Date().timeIntervalSince(cached.at) < reuseCandidatesWithin {
                candidates = cached.keys
            } else {
                candidates = await analysisOrderedRefKeys(dropboxStore: dropboxStore)
                cachedCandidates = (candidates, Date())
            }
            let pending = await people.pendingScanCount(candidateRefKeys: candidates)
            faceCandidates = candidates.count
            faceScanned = max(0, candidates.count - pending)
            faceMigration = await people.faceModelMigrationProgress(candidateRefKeys: candidates)
        }
        staleEmbeddings = await engine.pendingEmbeddingMigration()
    }

    @State private var cachedCandidates: (keys: [String], at: Date)?
    /// モデル更新の移行（ADR-186）: 旧モデルで作った埋め込みの残り／顔の影の世代の進み具合。
    @State private var staleEmbeddings = 0
    @State private var faceMigration: (scanned: Int, total: Int)?

    // MARK: - モデル更新（ADR-186）

    /// モデルが更新された後、索引を**少しずつ**新モデルへ移している間だけ出す。
    /// DB を丸ごと作り直さないので、この間も検索・ピープルは従来の結果で使える。
    private var modelUpdateSection: some View {
        Section {
            if staleEmbeddings > 0 {
                LabeledContent(L("Search index"), value: L("\(staleEmbeddings) left"))
            }
            if let m = faceMigration {
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

/// AI 解析の状況「画面」の出入りを **1 か所**で報告する修飾子。
///
/// ⚠️ `AIAnalysisStatusView` の `body` は `Section` の `Group` なので、そこに `.task` /
/// `.onDisappear` を付けると **Form の遅延生成でセクションごとに発火**する
/// （スクロールで `screenLeft()` が呼ばれ、前面のみモードの解析が止まる・レビュー指摘）。
/// 画面を包む `Form` に付けることで、出入りが 1 回ずつになる。
extension View {
    func analysisScreenLifecycle(_ session: AnalysisSession) -> some View {
        self
            .task {
                session.screenAppeared()
                // 継続タスクを使わない設定では、この画面を開いたときに中断の続きを再開する
                // （見ていない前面では走らせない・ADR-193）。
                await session.resumeIfPending(statusScreenOpen: true)
            }
            .onDisappear { session.screenLeft() }
    }
}
