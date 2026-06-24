import AutoAlbumCore
import BackupKit
import DropboxKit
import SwiftUI

/// Dropbox 関連の設定ハブ。接続（DropboxSettingsView）に加え、**接続済みになると**
/// Dropbox 前提の初期設定（バックアップ先・フォルダ名アルバム）への導線をその場に出す。
/// 「接続 → フォルダからアルバム / バックアップ」という一連のセットアップを1画面で完結させる。
struct DropboxHubView: View {
    let dropboxAuth: DropboxAuthService
    let store: DropboxPhotoStore?
    let backupEngine: BackupEngine
    let autoAlbumEngine: AutoAlbumEngine?

    var body: some View {
        Form {
            // 接続・サムネイル並列・キャッシュ上限（DropboxKit が提供するセクション群）。
            DropboxSettingsView(dropboxAuth: dropboxAuth, store: store)

            if dropboxAuth.connectionStatus == .connected {
                Section {
                    NavigationLink {
                        Form {
                            BackupSettingsView(dropboxAuth: dropboxAuth, engine: backupEngine, dropboxStore: store)
                        }
                        .navigationTitle("Backup")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("Back up photos to Dropbox", systemImage: "arrow.up.doc")
                    }
                    NavigationLink {
                        PathAlbumSettingsView(engine: autoAlbumEngine)
                    } label: {
                        Label("Make albums from folder names", systemImage: "folder")
                    }
                } header: {
                    Text("Use Dropbox for")
                } footer: {
                    Text("Set up backup and folder-name albums here right after connecting.")
                }
            }
        }
        .navigationTitle("Dropbox")
        .navigationBarTitleDisplayMode(.inline)
    }
}
