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
            semanticSearchSection
            sceneTagsSection
            if facesAvailable { peopleSection }
            actionSection
        }
        .task { await refresh() }
        .onChange(of: engine.isTagging) { _, _ in Task { await refresh() } }
        .onChange(of: people.isScanning) { _, _ in Task { await refresh() } }
        // 前面のみモードは画面を離れたら止める（継続モードは OS が面倒を見るので続く）。
        .onDisappear { session.screenLeft() }
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
                }
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
            Text("“Analyze Now” runs faces, tags, and the search index at full speed and keeps going after you leave the app — progress appears in the Dynamic Island / Lock Screen, where you can also stop it. It ends by itself when everything is analyzed, or if the battery drops below 20% while not charging.")
            + Text(verbatim: "\n\n")
            + Text("Locking the screen may pause it (a known iOS issue Apple is fixing). Keep Screen On avoids that — charging is recommended. The device may get warm; analysis pauses on its own if it gets too hot. Otherwise analysis runs automatically based on Processing Timing.")
        }
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
        }
    }

    private func stopText(_ reason: AnalysisSession.StopReason) -> String? {
        switch reason {
        case .finished: return L("Everything is analyzed.")
        case .expired: return L("iOS stopped the analysis. Tap Analyze Now to continue from where it left off.")
        case .lowBattery: return L("Stopped because the battery is low. Plug in and tap Analyze Now to continue.")
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

    private func refresh() async {
        async let prog = engine.analysisProgress()
        async let stats = people.scanStats()
        progress = await prog
        facesDetected = await stats.faces
        // 顔スキャンの分母は**候補そのもの**（スキャナと同じ列挙）、分子は「候補のうち済んだ数」。
        if facesAvailable {
            let candidates = await analysisOrderedRefKeys(dropboxStore: dropboxStore)
            let pending = await people.pendingScanCount(candidateRefKeys: candidates)
            faceCandidates = candidates.count
            faceScanned = max(0, candidates.count - pending)
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
