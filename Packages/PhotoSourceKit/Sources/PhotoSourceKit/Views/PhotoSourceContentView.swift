#if canImport(UIKit)
import SwiftUI

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
                    case .needsSetup(let message, let detail, let systemImage):
                        setupView(message: message, detail: detail, systemImage: systemImage)
                    case .loaded:
                        PhotoGridView(store: store)
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
            // Home / Settings バーは全状態（プレースホルダー含む）に表示する。
            // 未接続・空・失敗の各状態でもホーム/設定へ遷移できるようにするため。
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .task { await store.start() }
        .onChange(of: store.state) { _, newState in
            if case .idle = newState {
                Task { await store.start() }
            }
        }
    }

    // MARK: - Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if let dismissToHome {
                Button(action: dismissToHome) {
                    Label("Home", systemImage: "house")
                }
                .padding(.leading, 20)
            }
            Spacer()
            if let showSettings {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .accessibilityLabel("Settings")
                }
                .padding(.trailing, 20)
            }
        }
        .frame(height: 49)
        .background(.bar)
    }

    // MARK: - Placeholder views

    private func setupView(message: String, detail: String?, systemImage: String) -> some View {
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
        }
        .padding()
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No photos yet.")
        }
        .padding()
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Failed to load.")
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                Task { await store.retry() }
            }
        }
        .padding()
    }
}
#endif
