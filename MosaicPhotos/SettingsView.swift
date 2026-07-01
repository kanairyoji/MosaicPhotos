import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import MosaicSupport
import PhotosFeatureKit
import SwiftUI

/// 設定のルート。iOS 標準（Settings.app 風）のグループ化ナビゲーションリスト。
/// 各行は詳細画面へ遷移し、ソースの状態（Dropbox 接続など）は行に inline 表示する。
/// 詳細な診断・破壊的アクションは最下部の Developer Options に集約している。
struct SettingsView: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    let backupEngine: BackupEngine
    let placeScanner: PlaceScanner?
    let autoAlbumEngine: AutoAlbumEngine?
    let peopleEngine: PeopleEngine?
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) private var pathAlbumsEnabled = false
    @AppStorage(AppLocale.key) private var appLanguageRaw = AppLanguage.system.rawValue

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"

    /// オンライン版ヘルプ（設計資料と同じ GitHub Pages 上）。
    private static let helpURL = URL(string: "https://kanairyoji.github.io/MosaicPhotos/help/")!

    init(
        dropboxAuth: DropboxAuthService,
        store: DropboxPhotoStore? = nil,
        backupEngine: BackupEngine,
        placeScanner: PlaceScanner? = nil,
        autoAlbumEngine: AutoAlbumEngine? = nil,
        peopleEngine: PeopleEngine? = nil
    ) {
        self.dropboxAuth = dropboxAuth
        self.store = store
        self.backupEngine = backupEngine
        self.placeScanner = placeScanner
        self.autoAlbumEngine = autoAlbumEngine
        self.peopleEngine = peopleEngine
    }

    var body: some View {
        // NavigationStack is provided by HomeView / SourceHostView; do not nest one here.
        List {
            Section("Photo Sources") {
                NavigationLink {
                    detail(L("On-Device Photos")) { LocalPhotoSettingsView() }
                } label: {
                    row(L("On-Device Photos"), systemImage: "iphone")
                }
                NavigationLink {
                    DropboxHubView(dropboxAuth: dropboxAuth, store: store,
                                   backupEngine: backupEngine, autoAlbumEngine: autoAlbumEngine)
                } label: {
                    row("Dropbox", systemImage: "cloud", value: dropboxStatusText)   // ブランド名は非翻訳
                }
                NavigationLink {
                    detail(L("Backup")) {
                        BackupSettingsView(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
                    }
                } label: {
                    row(L("Backup"), systemImage: "arrow.up.doc")
                }
            }

            Section("Albums & Search") {
                NavigationLink {
                    detail(L("Auto Albums")) { AutoAlbumSettingsView(engine: autoAlbumEngine) }
                } label: {
                    row(L("Auto Albums"), systemImage: "sparkles")
                }
                NavigationLink {
                    PathAlbumSettingsView(engine: autoAlbumEngine)
                } label: {
                    row(L("Folder Albums"), systemImage: "folder", value: pathAlbumsEnabled ? L("On") : L("Off"))
                }
                NavigationLink {
                    detail(L("Places")) { PlacesSettingsView(scanner: placeScanner) }
                } label: {
                    row(L("Places"), systemImage: "mappin.and.ellipse")
                }
            }

            Section("General") {
                LabeledContent("Version", value: version)
                Picker("Language", selection: $appLanguageRaw) {
                    Text("System").tag(AppLanguage.system.rawValue)
                    Text(verbatim: "日本語").tag(AppLanguage.ja.rawValue)
                    Text(verbatim: "English").tag(AppLanguage.en.rawValue)
                }
                NavigationLink {
                    BackgroundSettingsView()
                } label: {
                    row(L("Background & Battery"), systemImage: "bolt.fill")
                }
                NavigationLink {
                    GridDisplaySettingsView()
                } label: {
                    row(L("Photo Grid"), systemImage: "square.grid.3x3")
                }
                NavigationLink {
                    StorageSettingsView(store: store, placeScanner: placeScanner)
                } label: {
                    row(L("Storage"), systemImage: "internaldrive")
                }
                NavigationLink {
                    LicensesView()
                } label: {
                    row(L("Licenses"), systemImage: "doc.text")
                }
                Link(destination: Self.helpURL) {
                    HStack {
                        Label(L("Help"), systemImage: "questionmark.circle")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)   // 通常の設定行と同じ見た目（リンク色にしない）
            }

            Section {
                NavigationLink {
                    DeveloperSettingsView(
                        dropboxAuth: dropboxAuth, store: store, backupEngine: backupEngine,
                        placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine,
                        peopleEngine: peopleEngine)
                } label: {
                    row(L("Developer Options"), systemImage: "hammer")
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel(L("Back"))
                }
            }
        }
    }

    // MARK: - Row / detail helpers

    private func row(_ title: String, systemImage: String, value: String? = nil) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if let value {
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }
    }

    /// セクション群を返す既存の設定ビュー（Form 非内包）を、タイトル付き Form でラップする詳細画面。
    @ViewBuilder
    private func detail<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form { content() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }

    private var dropboxStatusText: String? {
        switch dropboxAuth.connectionStatus {
        case .connected:      return L("Connected")
        case .authenticating: return L("Connecting…")
        case .notConnected:   return L("Not connected")
        case .error:          return L("Error")
        }
    }
}

/// 設定で共通利用するバイト数フォーマッタ。
func formattedBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
