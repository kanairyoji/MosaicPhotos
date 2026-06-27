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
    /// セクション構築は HomeSections.swift（extension）に分離しているため、そこから参照する
    /// プロパティは internal（private を付けない）にしている。
    @State var dropboxStore: DropboxPhotoStore
    @State private var mergedStore: MergedPhotoStore
    @State private var backupEngine: BackupEngine
    /// アルバムスキャナー。バックアップと独立してローカル写真ライブラリを走査・キャッシュする。
    @State var albumScanner: LocalAlbumScanner
    /// 場所（市区町村）スキャナー。ローカル＋Dropbox の位置情報をまとめてグルーピングする。
    @State var placeScanner: PlaceScanner
    /// 時間＋場所の自動アルバム生成エンジン（独立モジュール AutoAlbumCore）。
    /// Dropbox/バックアップのアダプタを注入し、ローカル＋クラウドを統合・重複排除して生成する。
    @State var autoAlbumEngine: AutoAlbumEngine
    /// フルスクリーン表示の対象（ソース/端末アルバム/場所/自動アルバム）。
    /// 4 つの `.fullScreenCover(item:)` を併用すると提示競合で別アルバムの中身が出る不具合があったため、
    /// 単一の `.fullScreenCover(item:)` ＋ enum に統合する（`.sheet` で採った対策と同じ）。
    @State var destination: HomeDestination?
    @State private var showingSettings = false
    /// AI アルバム作成/編集シートの対象（新規 or 既存）。
    /// 単一の `.sheet(item:)` に統合して、複数 .sheet 併用時の提示競合（編集が常に先頭になる不具合）を防ぐ。
    @State var aiComposer: AIComposerTarget?
    /// フォルダ名アルバム機能の有効フラグ（ON のときだけ「Albums」セクションを出す）。
    @AppStorage(AutoAlbumSettingsKeys.pathAlbumsEnabled) var pathAlbumsEnabled = false

    /// ストアは `HomeStores` で事前構築する（各ストアの `ModelContainer` 生成が同期的で重く、
    /// `HomeView.init` で作ると最初の描画＝起動をブロックするため）。`RootView` が起動直後に
    /// 非同期構築し、完成したものをここへ注入する。
    init(stores: HomeStores) {
        self._dropboxStore = State(initialValue: stores.dropboxStore)
        self._mergedStore = State(initialValue: stores.mergedStore)
        self._backupEngine = State(initialValue: stores.backupEngine)
        self._albumScanner = State(initialValue: stores.albumScanner)
        self._placeScanner = State(initialValue: stores.placeScanner)
        self._autoAlbumEngine = State(initialValue: stores.autoAlbumEngine)
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
            .safeAreaInset(edge: .bottom) { settingsBar }
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
        .fullScreenCover(item: $destination) { dest in
            sourceHost(dismiss: { destination = nil }) {
                switch dest {
                case .source(.all):
                    PhotoSourceContentView(store: mergedStore, title: "All Photos")
                case .source(.local):
                    LocalPhotoContentView()
                case .source(.cloud):
                    DropboxContentView(store: dropboxStore)
                case .localAlbum(let album):
                    LocalPhotoContentView(localIdentifiers: album.localIdentifiers, title: album.name)
                case .place(let place):
                    PlacePhotosView(place: place, dropboxStore: dropboxStore)
                case .autoAlbum(let album):
                    AutoAlbumPhotosView(album: album, dropboxStore: dropboxStore)
                }
            }
        }
        .modifier(HomeLifecycleTasks(
            dropboxStore: dropboxStore,
            backupEngine: backupEngine,
            placeScanner: placeScanner,
            albumScanner: albumScanner,
            autoAlbumEngine: autoAlbumEngine))
    }

    // MARK: - Settings bar

    private var settingsBar: some View {
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

    // MARK: - Source host wrapper

    /// 各フルスクリーン表示で共有する `SourceHostView` ラッパー。共有ストアの注入は一定で、
    /// dismiss クロージャと中身（content）だけが異なるため、ここに集約して重複を排除する。
    @ViewBuilder
    private func sourceHost<Content: View>(
        dismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        SourceHostView(
            dropboxStore: dropboxStore,
            backupEngine: backupEngine,
            placeScanner: placeScanner,
            autoAlbumEngine: autoAlbumEngine,
            dismissToHome: dismiss,
            content: content
        )
    }
}

// MARK: - Lifecycle tasks

/// HomeView のバックグラウンド処理（スキャン/生成のロードと定期差分チェック、Dropbox 同期トリガ）を
/// 1 つの ViewModifier にまとめ、`body` のルーティング記述から分離する。
private struct HomeLifecycleTasks: ViewModifier {
    let dropboxStore: DropboxPhotoStore
    let backupEngine: BackupEngine
    let placeScanner: PlaceScanner
    let albumScanner: LocalAlbumScanner
    let autoAlbumEngine: AutoAlbumEngine

    private var rescanIntervalSeconds: Int {
        let secs = UserDefaults.standard.integer(forKey: PlacesSettingsKeys.rescanIntervalSeconds)
        return secs > 0 ? secs : 10
    }

    func body(content: Content) -> some View {
        content
            // アルバムスキャン：キャッシュがあれば即ロード、なければバックグラウンドでスキャン。
            // バックアップとは独立して動作する。
            .task { await albumScanner.loadOrScan() }
            // 場所スキャン：ローカル＋Dropbox（同期済みの位置情報）をグルーピング。
            // 初回ロード後は一定間隔で差分チェックし、Dropbox 側の座標が増えたら動的に再スキャンする
            // （バックグラウンド同期や写真閲覧で座標が補完されると Places アルバムが増える）。
            .task {
                // 起動直後の同時スパイクを避けるため初回 place スキャンを少し遅らせる（ホームの初回描画を優先）。
                try? await Task.sleep(for: .seconds(1.5))
                await placeScanner.loadOrScan(dropboxItems: dropboxStore.items)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(rescanIntervalSeconds))
                    await placeScanner.refreshIfNeeded(dropboxItems: dropboxStore.items)
                }
            }
            // 自動アルバム（時間＋場所）：キャッシュ即ロード→無ければ生成。以降は写真追加で再生成。
            .task {
                await autoAlbumEngine.loadOrGenerate()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(rescanIntervalSeconds))
                    await autoAlbumEngine.refreshIfNeeded()
                }
            }
            // BackupSettingsView のデバッグ表示用のバックアップ記録ロードは起動表示に不要なので、
            // 起動スパイクを避けるため大きく遅延する（設定を開く頃には間に合う）。
            .task {
                try? await Task.sleep(for: .seconds(5))
                await backupEngine.loadAlbums()
            }
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
}
