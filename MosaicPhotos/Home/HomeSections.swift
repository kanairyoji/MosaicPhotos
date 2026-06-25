import AutoAlbumCore
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Home sections
//
// HomeView の `List` を構成する各セクションのビルダ。HomeView.swift は state・init（依存配線）と
// body（ルーティング）に専念し、セクションの見た目はここに集約する。
// extension が別ファイルから HomeView の格納プロパティへアクセスするため、参照先は internal にしている。

extension HomeView {

    // MARK: Sources section

    @ViewBuilder
    var sourceSection: some View {
        Section {
            SourceRow(
                systemImage: "photo.stack",
                tint: .indigo,
                title: "All Photos",
                subtitle: "Device + Dropbox combined"
            ) {
                destination = .source(.all)
            }

            SourceRow(
                systemImage: "iphone",
                tint: .blue,
                title: "On-Device Photos",
                subtitle: "Photos stored on this device"
            ) {
                destination = .source(.local)
            }

            SourceRow(
                systemImage: cloudIcon,
                tint: .cyan,
                title: "Cloud",
                subtitle: cloudSubtitle
            ) {
                destination = .source(.cloud)
            }
        } header: {
            Text("Sources")
        }
    }

    // MARK: Device albums section

    @ViewBuilder
    var albumsSection: some View {
        Section {
            if !albumScanner.isLoaded {
                // キャッシュロード / スキャン完了前
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading albums…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if albumScanner.albums.isEmpty {
                Label(
                    "No user-created albums found.",
                    systemImage: "rectangle.stack"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(albumScanner.albums) { album in
                    Button {
                        destination = .localAlbum(album)
                    } label: {
                        AlbumRow(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Device Albums")
                Spacer()
                if albumScanner.isScanning {
                    ProgressView().controlSize(.mini)
                } else if albumScanner.isLoaded {
                    Button {
                        Task { await albumScanner.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Places section

    @ViewBuilder
    var placesSection: some View {
        Section {
            if !placeScanner.isLoaded {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading places…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if placeScanner.places.isEmpty {
                Label("No photos with location found.", systemImage: "mappin.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(placeScanner.places) { place in
                    Button {
                        destination = .place(place)
                    } label: {
                        PlaceRow(place: place, dropboxStore: dropboxStore)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Places")
                Spacer()
                if placeScanner.isScanning {
                    ProgressView().controlSize(.mini)
                } else if placeScanner.isLoaded {
                    Button {
                        Task { await placeScanner.scan(dropboxItems: dropboxStore.items) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Auto albums section (時間＋場所)

    @ViewBuilder
    var autoAlbumsSection: some View {
        Section {
            if !autoAlbumEngine.isLoaded {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading albums…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else if autoAlbumEngine.albums.isEmpty {
                Label("No trip albums yet.", systemImage: "airplane")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AlbumCarousel(albums: autoAlbumEngine.albums, dropboxStore: dropboxStore) {
                    destination = .autoAlbum($0)
                }
            }
        } header: {
            HStack {
                Text("Time & Place")
                Spacer()
                if autoAlbumEngine.isGenerating {
                    ProgressView().controlSize(.mini)
                } else if autoAlbumEngine.isLoaded {
                    Button {
                        Task { await autoAlbumEngine.generate() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: AI albums section (自然文・オンデバイス)

    /// 自然文で作る AI アルバム。ヘッダーの「＋」でコンポーザーを開く。
    /// 表示は Time & Place と同じ横スクロールカルーセル。長押しで削除。
    @ViewBuilder
    var aiAlbumsSection: some View {
        Section {
            if autoAlbumEngine.aiAlbums.isEmpty {
                Button {
                    aiComposer = .create
                } label: {
                    Label("Describe an album — e.g. “Okinawa trips in recent years”.", systemImage: "sparkles")
                        .font(.callout)
                }
            } else {
                AlbumCarousel(
                    albums: autoAlbumEngine.aiAlbums, dropboxStore: dropboxStore,
                    onSelect: { destination = .autoAlbum($0) },
                    onEdit: { aiComposer = .edit($0) },
                    onDelete: { album in Task { await autoAlbumEngine.deleteAIAlbum(id: album.id) } })
            }
        } header: {
            HStack {
                Text("AI Albums")
                Spacer()
                Button {
                    aiComposer = .create
                } label: {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Path albums section (Dropbox フォルダ名から推測)

    /// フォルダ名アルバム（任意機能）。設定 ON のときセクションを表示する。
    /// 0 件でも空状態のヒントを出して「どこに表示されるか」を分かるようにする。
    /// 表示方法は Time & Place と同じ横スクロールカルーセル。
    @ViewBuilder
    var pathAlbumsSection: some View {
        if pathAlbumsEnabled {
            Section {
                if !autoAlbumEngine.isLoaded {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading albums…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else if autoAlbumEngine.pathAlbums.isEmpty {
                    Label("No folder albums yet. Add rules in Settings → Albums → Folder Albums, then regenerate.",
                          systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    AlbumCarousel(albums: autoAlbumEngine.pathAlbums, dropboxStore: dropboxStore) {
                        destination = .autoAlbum($0)
                    }
                }
            } header: {
                HStack {
                    Text("Albums")
                    Spacer()
                    if autoAlbumEngine.isGeneratingPath {
                        ProgressView().controlSize(.mini)
                    } else {
                        // フォルダ名アルバムだけの軽量再生成（地名解決なし・バックグラウンド）。
                        Button {
                            Task { await autoAlbumEngine.generatePathAlbums() }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Cloud icon / subtitle

    var cloudIcon: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:               return "cloud.fill"
        case .authenticating:          return "arrow.trianglehead.2.clockwise"
        case .notConnected, .error:    return "cloud.slash"
        }
    }

    var cloudSubtitle: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:      return "Dropbox · Connected"
        case .authenticating: return "Dropbox · Connecting..."
        case .notConnected:   return "Dropbox · Not connected"
        case .error:          return "Dropbox · Error"
        }
    }
}

// MARK: - Active source

enum ActiveSource: String, Identifiable {
    case all, local, cloud
    var id: String { rawValue }
}

// MARK: - Full-screen destination

/// ホームからフルスクリーン表示する対象。ソース（All/On-Device/Cloud）・端末アルバム・場所・
/// 自動アルバムを **単一の** `.fullScreenCover(item:)` で扱うための統合 enum。
/// 4 つの `.fullScreenCover` を併用すると提示競合で別アルバムの中身が表示される不具合があったため、
/// 1 つに集約する（`AIComposerTarget` で `.sheet` に適用したのと同じ対策）。
enum HomeDestination: Identifiable {
    case source(ActiveSource)
    case localAlbum(LocalAlbumInfo)
    case place(PlaceAlbumInfo)
    case autoAlbum(AutoAlbumInfo)

    var id: String {
        switch self {
        case .source(let source): return "source-\(source.id)"
        case .localAlbum(let album): return "album-\(album.id)"
        case .place(let place): return "place-\(place.id)"
        case .autoAlbum(let album): return "auto-\(album.id)"
        }
    }
}

// MARK: - AI composer target

/// AI アルバムシートの対象。新規作成と既存編集を1つの `.sheet(item:)` で扱う。
enum AIComposerTarget: Identifiable {
    case create
    case edit(AutoAlbumInfo)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let album): return album.id
        }
    }
}
