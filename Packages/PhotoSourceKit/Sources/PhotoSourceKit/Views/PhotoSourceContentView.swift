#if canImport(UIKit)
import SwiftUI
import UIKit
import MosaicSupport

/// Root view that dispatches to the correct sub-view based on `store.state`.
///
/// 任意で `header` を受け取り、グリッド画面の最上部（NavigationStack 内のルート）に表示する。
/// ヘッダーはルートにのみ付くため、写真フル表示（push された PhotoPageView）には被らず、
/// 戻るボタンを妨げない。
public struct PhotoSourceContentView<Store: PhotoStore, Header: View>: View {
    let store: Store
    let title: String
    let header: Header
    @Environment(\.dismissToHome) private var dismissToHome
    @Environment(\.showSettings)  private var showSettings
    @Environment(\.openURL)       private var openURL
    /// 絞り込み条件（お気に入りのみ等）。画面ごとの一時状態（開き直すと解除）。
    @State private var filter = PhotoFilter()
    @State private var showFilterSheet = false
    /// 顔ハイライト（人物アルバムのみ・環境で provider が注入されたときだけボタンを出す）。
    /// たまに確認したい機能なので既定 OFF・画面ごとの一時状態。
    @Environment(\.faceHighlightGridProvider) private var faceHighlightGrid
    @Environment(\.sourceMenuContent) private var sourceMenuContent
    @State private var showFaceBoxes = false
    /// ベストショット判定（フィルタ ON のとき台帳から読み込む・OFF で破棄）。
    @Environment(\.photoQualityProvider) private var photoQualityProvider
    @State private var beautifulMembership: (@Sendable (String) -> Bool)?

    public init(store: Store, title: String, @ViewBuilder header: () -> Header = { EmptyView() }) {
        self.store = store
        self.title = title
        self.header = header()
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Group {
                    switch store.state {
                    case .idle, .loading:
                        ProgressView()
                    case .needsSetup(let message, let detail, let systemImage, let action):
                        setupView(message: message, detail: detail, systemImage: systemImage, action: action)
                    case .loaded:
                        PhotoGridView(store: store, filter: filter,
                                      isBeautiful: beautifulMembership.map { member in
                                          { item in member("\(item.id)") }
                                      },
                                      faceHighlight: showFaceBoxes ? faceHighlightGrid : nil)
                    case .empty:
                        emptyView
                    case .failed(let message):
                        failedView(message: message)
                    }
                }
                // プレースホルダー（中央寄せの小さな内容）でも画面いっぱいに広げ、
                // 下部バーが常に画面最下部へ固定されるようにする（grid 表示時と同じ見た目）。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(title)
            // アルバム画面内の「…」メニュー（ホームカードの「…」/長押しと同じ操作を画面内でも）。
            .toolbar {
                // アルバム画面内の操作。中身（Menu か …→ダイアログ か）は呼び出し側が決める
                //（AI アルバム＝Menu、人物＝…ボタン→確認ダイアログ）。
                if let sourceMenuContent {
                    ToolbarItem(placement: .topBarTrailing) { sourceMenuContent() }
                }
            }
            // Home / Settings バーは全状態（プレースホルダー含む）に表示する。
            // 未接続・空・失敗の各状態でもホーム/設定へ遷移できるようにするため。
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .task { await store.start() }
        // ベストショット判定集合の読み込み（フィルタ ON のときだけ・OFF で解放）。
        .task(id: filter.beautifulOnly) {
            guard filter.beautifulOnly, let photoQualityProvider else {
                beautifulMembership = nil
                return
            }
            beautifulMembership = await photoQualityProvider()
        }
        // 計測: ソース画面が出てから最初のコンテンツ（loaded/empty）が確定するまでの所要。
        // 「画面遷移後にグリッドが見えるまで」が重いケースを掴むため。
        .onAppear { PerfTrace.beginScreen("grid.\(title)") }
        .onChange(of: store.state) { _, newState in
            switch newState {
            case .idle:
                Task { await store.start() }
            case .loaded, .empty, .failed, .needsSetup:
                PerfTrace.endScreen("grid.\(title)")
            case .loading:
                break
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if let dismissToHome {
                Button(action: dismissToHome) {
                    Label(L("Home"), systemImage: "house")
                }
                .padding(.leading, 20)
            }
            Spacer()
            // フィルタ（Home と Settings の間・中央）。有効中はアイコンを塗り＋アクセント色で示す。
            Button { showFilterSheet = true } label: {
                Image(systemName: filter.isActive
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(filter.isActive ? Color.accentColor : Color.primary)
                    .accessibilityLabel(L("Filter"))
            }
            Spacer()
            // 顔ハイライト（人物アルバムのみ）。Home/歯車と同列の下部バーに、一目で分かる
            // 「顔マーク」で出す（person.and.viewfinder は何の機能か伝わらなかった＝実フィードバック）。
            // ON 中は塗り＋黄色でサムネに認識した顔の黄枠を重ねる。
            if faceHighlightGrid != nil {
                Button { showFaceBoxes.toggle() } label: {
                    Image(systemName: showFaceBoxes ? "face.smiling.inverse" : "face.smiling")
                        .foregroundStyle(showFaceBoxes ? Color.yellow : Color.primary)
                        .accessibilityLabel(L("Show recognized face"))
                }
                Spacer()
            }
            if let showSettings {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .accessibilityLabel(L("Settings"))
                }
                .padding(.trailing, 20)
            }
        }
        .frame(height: 49)
        .background(.bar)
        .sheet(isPresented: $showFilterSheet) {
            // ソース欄は混在ソースのビューのみ（単一ソースでは意味がないため出さない）。
            // ベストショット欄は判定プロバイダが注入されているときのみ（AI 台帳が背後に必要）。
            PhotoFilterSheet(filter: $filter, showsSourceOptions: store.isMixedSource,
                             showsQualityOption: photoQualityProvider != nil)
        }
    }

    // MARK: - Placeholder views

    private func setupView(message: String, detail: String?, systemImage: String, action: SetupAction?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                setupActionButton(action)
            }
        }
        .padding()
    }

    /// 解決アクションのボタン。OS 権限は iOS「設定」アプリ、アプリ内設定（Dropbox 接続）は設定シート。
    @ViewBuilder
    private func setupActionButton(_ action: SetupAction) -> some View {
        switch action {
        case .openSystemSettings:
            Button(L("Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        case .openAppSettings:
            if let showSettings {
                Button(L("Open Settings"), action: showSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(L("No photos yet."))
        }
        .padding()
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(L("Failed to load."))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(L("Retry")) {
                Task { await store.retry() }
            }
        }
        .padding()
    }
}
#endif
