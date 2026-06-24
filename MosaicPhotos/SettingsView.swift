import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
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
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) private var pathAlbumsEnabled = false

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"

    init(
        dropboxAuth: DropboxAuthService,
        store: DropboxPhotoStore? = nil,
        backupEngine: BackupEngine,
        placeScanner: PlaceScanner? = nil,
        autoAlbumEngine: AutoAlbumEngine? = nil
    ) {
        self.dropboxAuth = dropboxAuth
        self.store = store
        self.backupEngine = backupEngine
        self.placeScanner = placeScanner
        self.autoAlbumEngine = autoAlbumEngine
    }

    var body: some View {
        // NavigationStack is provided by HomeView / SourceHostView; do not nest one here.
        List {
            Section("Photo Sources") {
                NavigationLink {
                    detail("Photos") { LocalPhotoSettingsView() }
                } label: {
                    row("Photos", systemImage: "iphone")
                }
                NavigationLink {
                    DropboxHubView(dropboxAuth: dropboxAuth, store: store,
                                   backupEngine: backupEngine, autoAlbumEngine: autoAlbumEngine)
                } label: {
                    row("Dropbox", systemImage: "cloud", value: dropboxStatusText)
                }
                NavigationLink {
                    detail("Backup") {
                        BackupSettingsView(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
                    }
                } label: {
                    row("Backup", systemImage: "arrow.up.doc")
                }
            }

            Section("Albums & Search") {
                NavigationLink {
                    detail("Auto Albums") { AutoAlbumSettingsView(engine: autoAlbumEngine) }
                } label: {
                    row("Auto Albums", systemImage: "sparkles")
                }
                NavigationLink {
                    PathAlbumSettingsView(engine: autoAlbumEngine)
                } label: {
                    row("Folder Albums", systemImage: "folder", value: pathAlbumsEnabled ? "On" : "Off")
                }
                NavigationLink {
                    detail("Places") { PlacesSettingsView(scanner: placeScanner) }
                } label: {
                    row("Places", systemImage: "mappin.and.ellipse")
                }
            }

            Section("General") {
                LabeledContent("Version", value: version)
                NavigationLink {
                    StorageSettingsView(store: store, placeScanner: placeScanner)
                } label: {
                    row("Storage", systemImage: "internaldrive")
                }
            }

            Section {
                NavigationLink {
                    DeveloperSettingsView(
                        dropboxAuth: dropboxAuth, store: store, backupEngine: backupEngine,
                        placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine)
                } label: {
                    row("Developer Options", systemImage: "hammer")
                }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel("Back")
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
        case .connected:      return "Connected"
        case .authenticating: return "Connecting…"
        case .notConnected:   return "Not connected"
        case .error:          return "Error"
        }
    }
}

/// 設定で共通利用するバイト数フォーマッタ。
func formattedBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
