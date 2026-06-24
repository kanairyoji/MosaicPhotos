import AutoAlbumCore
import BackupKit
import DropboxKit
import LocalPhotoKit
import PhotosFeatureKit
import PhotoSourceKit
import SwiftUI

// MARK: - Root home view

struct HomeView: View {
    /// auth・dropboxStore・backupEngine の 3 つは同一の DropboxAuthService を共有する。
    /// mergedStore は dropboxStore を注入して共有 NSCache を維持する。
    /// @State の default value 式は相互参照できないため、カスタム init でまとめて初期化する。
    @State private var dropboxStore: DropboxPhotoStore
    @State private var mergedStore: MergedPhotoStore
    @State private var backupEngine: BackupEngine
    /// アルバムスキャナー。バックアップと独立してローカル写真ライブラリを走査・キャッシュする。
    @State private var albumScanner = LocalAlbumScanner()
    /// 場所（市区町村）スキャナー。ローカル＋Dropbox の位置情報をまとめてグルーピングする。
    @State private var placeScanner = PlaceScanner()
    /// 時間＋場所の自動アルバム生成エンジン（独立モジュール AutoAlbumCore）。
    /// Dropbox/バックアップのアダプタを注入し、ローカル＋クラウドを統合・重複排除して生成する。
    @State private var autoAlbumEngine: AutoAlbumEngine
    @State private var activeSource: ActiveSource?
    @State private var selectedAlbum: LocalAlbumInfo?
    @State private var selectedPlace: PlaceAlbumInfo?
    @State private var selectedAutoAlbum: AutoAlbumInfo?
    @State private var showingSettings = false
    /// AI アルバム作成/編集シートの対象（新規 or 既存）。
    /// 単一の `.sheet(item:)` に統合して、複数 .sheet 併用時の提示競合（編集が常に先頭になる不具合）を防ぐ。
    @State private var aiComposer: AIComposerTarget?
    /// フォルダ名アルバム機能の有効フラグ（ON のときだけ「Albums」セクションを出す）。
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) private var pathAlbumsEnabled = false

    init() {
        let auth = DropboxAuthService(appKey: DropboxConfig.appKey, redirectURI: DropboxConfig.redirectURI)
        let dropboxStore = DropboxPhotoStore(auth: auth)
        self._dropboxStore = State(initialValue: dropboxStore)
        self._mergedStore = State(initialValue: MergedPhotoStore(dropboxStore: dropboxStore))
        let backupEngine = BackupEngine(auth: auth)
        self._backupEngine = State(initialValue: backupEngine)
        self._autoAlbumEngine = State(initialValue:
            makeAutoAlbumEngine(dropboxStore: dropboxStore, backupEngine: backupEngine))
    }

    var body: some View {
        NavigationStack {
            List {
                sourceSection
                autoAlbumsSection
                aiAlbumsSection
                pathAlbumsSection
                albumsSection
                placesSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("MosaicPhotos")
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel("Settings")
                    }
                    .padding(.trailing, 20)
                }
                .frame(height: 49)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView(dropboxAuth: dropboxStore.auth, store: dropboxStore, backupEngine: backupEngine,
                             placeScanner: placeScanner, autoAlbumEngine: autoAlbumEngine)
            }
        }
        .sheet(item: $aiComposer) { target in
            switch target {
            case .create:
                AIAlbumComposerView(engine: autoAlbumEngine)
            case .edit(let album):
                AIAlbumComposerView(engine: autoAlbumEngine, editing: album)
            }
        }
        .fullScreenCover(item: $activeSource) { source in
            SourceHostView(
                dropboxStore: dropboxStore,
                backupEngine: backupEngine,
                placeScanner: placeScanner,
                autoAlbumEngine: autoAlbumEngine,
                dismissToHome: { activeSource = nil }
            ) {
                switch source {
                case .all:
                    PhotoSourceContentView(store: mergedStore, title: "All Photos")
                case .local:
                    LocalPhotoContentView()
                case .cloud:
                    DropboxContentView(store: dropboxStore)
                }
            }
        }
        .fullScreenCover(item: $selectedAlbum) { album in
            SourceHostView(
                dropboxStore: dropboxStore,
                backupEngine: backupEngine,
                placeScanner: placeScanner,
                autoAlbumEngine: autoAlbumEngine,
                dismissToHome: { selectedAlbum = nil }
            ) {
                LocalPhotoContentView(localIdentifiers: album.localIdentifiers, title: album.name)
            }
        }
        .fullScreenCover(item: $selectedPlace) { place in
            SourceHostView(
                dropboxStore: dropboxStore,
                backupEngine: backupEngine,
                placeScanner: placeScanner,
                autoAlbumEngine: autoAlbumEngine,
                dismissToHome: { selectedPlace = nil }
            ) {
                PlacePhotosView(place: place, dropboxStore: dropboxStore)
            }
        }
        .fullScreenCover(item: $selectedAutoAlbum) { album in
            SourceHostView(
                dropboxStore: dropboxStore,
                backupEngine: backupEngine,
                placeScanner: placeScanner,
                autoAlbumEngine: autoAlbumEngine,
                dismissToHome: { selectedAutoAlbum = nil }
            ) {
                AutoAlbumPhotosView(album: album, dropboxStore: dropboxStore)
            }
        }
        // アルバムスキャン：キャッシュがあれば即ロード、なければバックグラウンドでスキャン。
        // バックアップとは独立して動作する。
        .task { await albumScanner.loadOrScan() }
        // 場所スキャン：ローカル＋Dropbox（同期済みの位置情報）をグルーピング。
        // 初回ロード後は 10 秒ごとに差分チェックし、Dropbox 側の座標が増えたら動的に再スキャンする
        // （バックグラウンド同期や写真閲覧で座標が補完されると Places アルバムが増える）。
        .task {
            await placeScanner.loadOrScan(dropboxItems: dropboxStore.items)
            while !Task.isCancelled {
                let secs = UserDefaults.standard.integer(forKey: PlacesSettingsKeys.rescanIntervalSeconds)
                try? await Task.sleep(for: .seconds(secs > 0 ? secs : 10))
                await placeScanner.refreshIfNeeded(dropboxItems: dropboxStore.items)
            }
        }
        // 自動アルバム（時間＋場所）：キャッシュ即ロード→無ければ生成。以降は写真追加で再生成。
        .task {
            await autoAlbumEngine.loadOrGenerate()
            while !Task.isCancelled {
                let secs = UserDefaults.standard.integer(forKey: PlacesSettingsKeys.rescanIntervalSeconds)
                try? await Task.sleep(for: .seconds(secs > 0 ? secs : 10))
                await autoAlbumEngine.refreshIfNeeded()
            }
        }
        // BackupSettingsView のデバッグ表示用にバックアップ記録もロードしておく。
        .task { await backupEngine.loadAlbums() }
        .onChange(of: dropboxStore.auth.connectionStatus) { _, newStatus in
            switch newStatus {
            case .connected:
                dropboxStore.startSync()
            case .notConnected, .error:
                dropboxStore.reset()
            case .authenticating:
                break
            }
        }
        .onAppear {
            if case .connected = dropboxStore.auth.connectionStatus {
                dropboxStore.startSync()
                let folder = UserDefaults.standard.string(forKey: BackupSettingsKeys.dropboxFolder) ?? "/MosaicPhotos"
                Task { await dropboxStore.loadBackupMetadata(from: folder) }
            }
        }
    }

    // MARK: - Sources section

    @ViewBuilder
    private var sourceSection: some View {
        Section {
            SourceRow(
                systemImage: "photo.stack",
                tint: .indigo,
                title: "All Photos",
                subtitle: "Device + Dropbox combined"
            ) {
                activeSource = .all
            }

            SourceRow(
                systemImage: "iphone",
                tint: .blue,
                title: "Photos",
                subtitle: "Browse your device photos"
            ) {
                activeSource = .local
            }

            SourceRow(
                systemImage: cloudIcon,
                tint: .cyan,
                title: "Cloud",
                subtitle: cloudSubtitle
            ) {
                activeSource = .cloud
            }
        } header: {
            Text("Sources")
        }
    }

    // MARK: - Albums section

    @ViewBuilder
    private var albumsSection: some View {
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
                        selectedAlbum = album
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

    // MARK: - Places section

    @ViewBuilder
    private var placesSection: some View {
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
                        selectedPlace = place
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

    // MARK: - Auto albums section (時間＋場所)

    @ViewBuilder
    private var autoAlbumsSection: some View {
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
                    selectedAutoAlbum = $0
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

    // MARK: - AI albums section (自然文・オンデバイス)

    /// 自然文で作る AI アルバム。ヘッダーの「＋」でコンポーザーを開く。
    /// 表示は Time & Place と同じ横スクロールカルーセル。長押しで削除。
    @ViewBuilder
    private var aiAlbumsSection: some View {
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
                    onSelect: { selectedAutoAlbum = $0 },
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

    // MARK: - Path albums section (Dropbox フォルダ名から推測)

    /// フォルダ名アルバム（任意機能）。設定 ON のときセクションを表示する。
    /// 0 件でも空状態のヒントを出して「どこに表示されるか」を分かるようにする。
    /// 表示方法は Time & Place と同じ横スクロールカルーセル。
    @ViewBuilder
    private var pathAlbumsSection: some View {
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
                        selectedAutoAlbum = $0
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

    // MARK: - Cloud icon / subtitle

    private var cloudIcon: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:               return "cloud.fill"
        case .authenticating:          return "arrow.trianglehead.2.clockwise"
        case .notConnected, .error:    return "cloud.slash"
        }
    }

    private var cloudSubtitle: String {
        switch dropboxStore.auth.connectionStatus {
        case .connected:      return "Dropbox · Connected"
        case .authenticating: return "Dropbox · Connecting..."
        case .notConnected:   return "Dropbox · Not connected"
        case .error:          return "Dropbox · Error"
        }
    }
}

// MARK: - Active source

private enum ActiveSource: String, Identifiable {
    case all, local, cloud
    var id: String { rawValue }
}

// MARK: - AI composer target

/// AI アルバムシートの対象。新規作成と既存編集を1つの `.sheet(item:)` で扱う。
private enum AIComposerTarget: Identifiable {
    case create
    case edit(AutoAlbumInfo)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let album): return album.id
        }
    }
}
