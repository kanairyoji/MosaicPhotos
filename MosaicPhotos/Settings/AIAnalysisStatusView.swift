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

    @State private var progress = AnalysisProgress(total: 0, embedded: 0, sceneTagged: 0, captioned: 0)
    @State private var faceScanned = 0
    @State private var facesDetected = 0
    @State private var localPhotoTotal = 0

    private var monitor: BackgroundActivityMonitor { .shared }
    private var captionsAvailable: Bool { VLM.modelsBundled }
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
            if captionsAvailable { captionsSection }
            if facesAvailable { peopleSection }
            actionSection
        }
        .task { await refresh() }
        .onChange(of: engine.isTagging) { _, _ in Task { await refresh() } }
        .onChange(of: people.isScanning) { _, _ in Task { await refresh() } }
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

    // MARK: - キャプション（AI による説明）

    private var captionsSection: some View {
        Section {
            progressRow(done: progress.captioned, total: progress.captionableTotal, running: engine.isTagging)
            lastRunRow(.captions)
            // 生成された説明文を実際に一覧で確認する（動いているかを目視で確かめる）。
            if progress.captioned > 0 {
                NavigationLink {
                    CaptionedPhotosView(engine: engine, mergedStore: mergedStore)
                } label: {
                    Label(L("Review descriptions"), systemImage: "text.magnifyingglass")
                }
            }
        } header: {
            Text("AI Descriptions")
        } footer: {
            Text("A one-sentence description generated on device, for your favorite photos only (it's the heaviest pass). Mark photos as favorites to have them described.")
        }
    }

    // MARK: - ピープル（顔）

    private var peopleSection: some View {
        Section {
            progressRow(done: faceScanned, total: localPhotoTotal, running: people.isScanning)
            LabeledContent(L("People found"), value: "\(people.people.count)")
            LabeledContent(L("Faces detected"), value: "\(facesDetected)")
            lastRunRow(.faces)
        } header: {
            Text("People")
        } footer: {
            Text("Faces are detected in your device photos and grouped into people, entirely on device. Cloud photos are not scanned for faces.")
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            Button {
                BackgroundYield.boostHeavyWork()
                engine.scheduleBackgroundFill()
                if facesAvailable, !people.isScanning {
                    Task { people.startScan(candidateRefKeys: await allImageRefKeys(dropboxStore: dropboxStore)) }
                }
            } label: {
                Label(L("Analyze Now (while charging)"), systemImage: "bolt.badge.clock")
            }
            .disabled(isAnalyzing)
            NavigationLink {
                Form { AutoAlbumSettingsView(engine: engine) }
                    .navigationTitle(L("Auto Albums"))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(L("Processing Timing & Speed"), systemImage: "slider.horizontal.3")
            }
        } footer: {
            Text("“Analyze Now” starts immediately for 30 minutes — your iPhone must be charging. Otherwise analysis runs automatically based on Processing Timing (by default while charging, on Wi-Fi, and not in use).")
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
        async let localTotal: Int = facesAvailable ? localImagePhotoCount() : 0
        progress = await prog
        let s = await stats
        faceScanned = s.scanned
        facesDetected = s.faces
        // 顔スキャンは端末＋クラウド両方が対象になったので分母も合算（クラウドは同期済み件数）。
        localPhotoTotal = await localTotal + (facesAvailable ? dropboxStore.items.count : 0)
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
