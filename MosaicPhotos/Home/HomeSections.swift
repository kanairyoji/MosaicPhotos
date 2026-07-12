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
                title: L("All Photos"),
                subtitle: L("Device + Dropbox combined")
            ) {
                destination = .source(.all)
            }

            SourceRow(
                systemImage: "iphone",
                tint: .blue,
                title: L("On-Device Photos"),
                subtitle: L("Photos stored on this device")
            ) {
                destination = .source(.local)
            }

            SourceRow(
                systemImage: cloudIcon,
                tint: .cyan,
                title: L("Cloud"),
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
                LoadingRow("Loading albums…")
            } else if albumScanner.albums.isEmpty {
                Label(
                    "No user-created albums found.",
                    systemImage: "rectangle.stack"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                // 他のアルバム（Time & Place / AI / フォルダ）と同じ横スクロールカルーセルで表示する。
                LibraryCarousel(
                    items: albumScanner.albums,
                    title: { $0.name },
                    subtitle: { photoCountText($0.photoCount) },
                    placeholderSystemImage: "photo.on.rectangle",
                    cover: { album in
                        await loadLocalCover(album.coverLocalIdentifier, pixelSize: 300)
                    },
                    onSelect: { destination = .localAlbum($0) })
            }
        } header: {
            sectionHeader("Device Albums", isBusy: albumScanner.isScanning,
                          onAction: albumScanner.isLoaded ? { Task { await albumScanner.scan() } } : nil)
        }
    }

    // MARK: Places section

    @ViewBuilder
    var placesSection: some View {
        Section {
            if !placeScanner.isLoaded {
                LoadingRow("Loading places…")
            } else if placeScanner.places.isEmpty {
                Label("No photos with location found.", systemImage: "mappin.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 他のアルバムと同じ横スクロールカルーセルで表示する。
                LibraryCarousel(
                    items: placeScanner.places,
                    title: { $0.placeName },
                    subtitle: { photoCountText($0.photoCount) },
                    placeholderSystemImage: "mappin.and.ellipse",
                    cover: { [dropboxStore] place in
                        // ローカルがあれば PHAsset、無ければ Dropbox（フル画像からカバー生成）。
                        await loadCover(localID: place.coverLocalID, cloudPath: place.coverCloudPath,
                                        dropboxStore: dropboxStore, maxPixel: 300)
                    },
                    onSelect: { destination = .place($0) })
            }
        } header: {
            sectionHeader("Places", isBusy: placeScanner.isScanning,
                          onAction: placeScanner.isLoaded
                              ? { Task { await placeScanner.scan(dropboxItems: dropboxStore.items) } }
                              : nil)
        }
    }

    // MARK: Auto albums section (時間＋場所)

    @ViewBuilder
    var autoAlbumsSection: some View {
        Section {
            if !autoAlbumEngine.isLoaded {
                LoadingRow("Loading albums…")
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
            sectionHeader("Time & Place", isBusy: autoAlbumEngine.isGenerating,
                          onAction: autoAlbumEngine.isLoaded ? { Task { await autoAlbumEngine.generate() } } : nil)
        }
    }

    // MARK: People section (端末写真の顔クラスタ＝オンデバイス Vision+CLIP 顔モデル)

    /// 端末写真を顔検出＋クラスタリングして得た「人物」を、円形アバターの横スクロールで表示する。
    /// 表示は Time & Place の直下。タップでその人物の写真一覧へ。顔モデル未同梱なら非表示。
    @ViewBuilder
    var peopleSection: some View {
        if peopleEngine.isFaceModelAvailable {
            Section {
                if peopleEngine.people.isEmpty {
                    if peopleEngine.isScanning {
                        LoadingRow("Finding people…")
                    } else {
                        Label("No people found yet.", systemImage: "person.crop.circle.badge.questionmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    PeopleCarousel(
                        people: peopleEngine.people,
                        onSelect: { destination = .person($0) },
                        onLongPress: { personActions = $0 })
                }
            } header: {
                sectionHeader("People", isBusy: peopleEngine.isScanning)
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
            sectionHeader("AI Albums", isBusy: autoAlbumEngine.isMakingAIAlbum, actionIcon: "plus",
                          onAction: { aiComposer = .create })
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
                    LoadingRow("Loading albums…")
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
                // フォルダ名アルバムだけの軽量再生成（地名解決なし・バックグラウンド）。
                sectionHeader("Albums", isBusy: autoAlbumEngine.isGeneratingPath,
                              onAction: { Task { await autoAlbumEngine.generatePathAlbums() } })
            }
        }
    }

    // MARK: Cloud icon / subtitle

    var cloudIcon: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:               return "cloud.fill"
        case .authenticating:          return "arrow.trianglehead.2.clockwise"
        case .notConnected, .error:    return "icloud.slash"
        }
    }

    var cloudSubtitle: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:      return L("Dropbox · Connected")
        case .authenticating: return L("Dropbox · Connecting...")
        case .notConnected:   return L("Dropbox · Not connected")
        case .error:          return L("Dropbox · Error")
        }
    }
}

// MARK: - Section building blocks（各セクション共通の部品）

/// セクションヘッダ共通部品：タイトル＋右端に「実行中スピナー or アクションボタン」。
/// `isBusy` 中は mini スピナー、そうでなければ `onAction`（省略可）のアイコンボタンを出す。
@ViewBuilder
private func sectionHeader(_ title: LocalizedStringKey, isBusy: Bool,
                           actionIcon: String = "arrow.clockwise",
                           onAction: (() -> Void)? = nil) -> some View {
    HStack {
        Text(title)
        Spacer()
        if isBusy {
            ProgressView().controlSize(.mini)
        } else if let onAction {
            Button(action: onAction) {
                Image(systemName: actionIcon).font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

/// セクションのロード中に出す行（小スピナー＋説明文）。
private struct LoadingRow: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
    case person(PersonInfo)
    case place(PlaceAlbumInfo)
    case autoAlbum(AutoAlbumInfo)

    var id: String {
        switch self {
        case .source(let source): return "source-\(source.id)"
        case .localAlbum(let album): return "album-\(album.id)"
        case .person(let person): return "person-\(person.id)"
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
