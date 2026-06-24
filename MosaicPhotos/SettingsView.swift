import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import SwiftUI

private enum SettingsTab {
    case general, photos, dropbox, backup, places, albums
}

struct SettingsView: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    let backupEngine: BackupEngine
    let placeScanner: PlaceScanner?
    let autoAlbumEngine: AutoAlbumEngine?
    @State private var selectedTab: SettingsTab = .general
    @Environment(\.dismiss) private var dismiss

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
        // NavigationStack is provided by HomeView; do not nest one here.
        Form {
            Picker("", selection: $selectedTab) {
                Text("General").tag(SettingsTab.general)
                Text("Photos").tag(SettingsTab.photos)
                Text("Cloud").tag(SettingsTab.dropbox)
                Text("Backup").tag(SettingsTab.backup)
                Text("Places").tag(SettingsTab.places)
                Text("Albums").tag(SettingsTab.albums)
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .general:
                GeneralSettingsView()
                Section {
                    NavigationLink("Developer Options") {
                        DeveloperSettingsView(
                            dropboxAuth: dropboxAuth, store: store, backupEngine: backupEngine,
                            placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine)
                    }
                }
            case .photos:
                LocalPhotoSettingsView()
            case .dropbox:
                DropboxSettingsView(dropboxAuth: dropboxAuth, store: store)
            case .backup:
                BackupSettingsView(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
            case .places:
                PlacesSettingsView(scanner: placeScanner)
            case .albums:
                AutoAlbumSettingsView(engine: autoAlbumEngine)
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
}

/// 設定で共通利用するバイト数フォーマッタ。
func formattedBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
